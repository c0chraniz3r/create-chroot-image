#!/usr/bin/env bash
#
# create_chroot_image.sh
#
# Creates a Debian/Ubuntu chroot with Synaptic, lets user pick a DE via Synaptic,
# updates the chroot, and copies it into a raw EFI-bootable disk image for USB.
#
# Usage: sudo ./create_chroot_image.sh
#
set -euo pipefail
IFS=$'\n\t'

# ---------- Configuration ----------
CHROOT_DIR="${PWD}/chroot"        # where debootstrap will create the chroot
IMAGE_FILE="${PWD}/usb_image.img" # output raw image (will be overwritten)
IMAGE_SIZE="4G"                   # default image size (changeable on prompt)
ARCH="amd64"
HOST_DEPS=(debootstrap qemu-utils parted dosfstools gdisk mtools kpartx rsync xauth x11-xserver-utils wget curl apt-transport-https)
# ---------- End configuration ----------

# Utility: print and exit on error
err() { echo "ERROR: $*" >&2; exit 1; }

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
  err "This script must be run as root (sudo)."
fi

# 0. Install necessary packages on host
echo "Installing required host packages..."
apt-get update
apt-get install -y "${HOST_DEPS[@]}"

# Prompt distro family
echo
PS3="Choose the distro family to debootstrap into the chroot: "
options=("Debian" "Ubuntu" "Quit")
select distro_family in "${options[@]}"; do
  case "$distro_family" in
    Debian|Ubuntu) break ;;
    Quit) echo "Aborted by user."; exit 1 ;;
    *) echo "Invalid selection." ;;
  esac
done

# Provide suites depending on family
declare -a suites
if [ "$distro_family" = "Debian" ]; then
  suites=(bookworm bullseye buster bookworm-backports)
elif [ "$distro_family" = "Ubuntu" ]; then
  suites=(jammy focal kinetic impish)
fi

echo "Available suites for $distro_family:"
select suite in "${suites[@]}" "Quit"; do
  if [ "$suite" = "Quit" ]; then echo "Aborted by user."; exit 1; fi
  if [[ -n "$suite" ]]; then break; fi
  echo "Invalid selection."
done

echo "Selected: $distro_family $suite"
echo

# Confirm or change CHROOT_DIR
read -rp "Chroot target directory (default: ${CHROOT_DIR}): " input
CHROOT_DIR="${input:-$CHROOT_DIR}"

mkdir -p "$CHROOT_DIR"

# 1-2. Debootstrap the system chroot
echo "Starting debootstrap of $distro_family $suite into $CHROOT_DIR ..."
if [ "$distro_family" = "Debian" ]; then
  debootstrap --arch="$ARCH" --variant=minbase "$suite" "$CHROOT_DIR" http://deb.debian.org/debian/
else
  debootstrap --arch="$ARCH" --variant=minbase "$suite" "$CHROOT_DIR" http://archive.ubuntu.com/ubuntu/
fi
echo "debootstrap finished."

# Basic bind mounts
mount_bind() {
  mount --bind /dev "$CHROOT_DIR/dev"
  mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
  mount -t proc /proc "$CHROOT_DIR/proc"
  mount -t sysfs /sys "$CHROOT_DIR/sys"
  # copy resolv for networking in chroot
  cp -L /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"
}
umount_bind() {
  set +e
  umount -l "$CHROOT_DIR/dev/pts" || true
  umount -l "$CHROOT_DIR/dev" || true
  umount -l "$CHROOT_DIR/proc" || true
  umount -l "$CHROOT_DIR/sys" || true
  set -e
}

mount_bind

# Minimal /etc/apt/sources.list in chroot
cat > "$CHROOT_DIR/etc/apt/sources.list" <<EOF
deb $( [ "$distro_family" = "Debian" ] && echo "http://deb.debian.org/debian" || echo "http://archive.ubuntu.com/ubuntu" ) $suite main restricted universe multiverse
deb-src $( [ "$distro_family" = "Debian" ] && echo "http://deb.debian.org/debian" || echo "http://archive.ubuntu.com/ubuntu" ) $suite main restricted universe multiverse
EOF

# Prepare chroot environment: create a minimal locale and utilities
chroot_cmd() { chroot "$CHROOT_DIR" /bin/bash -lc "$*"; }
echo "Preparing chroot (apt update, install base utilities)..."
chroot_cmd "apt-get update"
chroot_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends apt-utils dialog locales ca-certificates gnupg2 wget curl"

# Set locale (optional)
chroot_cmd "locale-gen en_US.UTF-8 || true"
chroot_cmd "update-ca-certificates || true"

# 3. Automatically install Synaptic in the chroot
echo "Installing Synaptic and GUI helpers inside chroot..."
chroot_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends synaptic dbus-x11 x11-utils xauth sudo"

# Create a normal user for convenience (not strictly necessary)
CHROOT_USER="user"
chroot_cmd "id -u $CHROOT_USER >/dev/null 2>&1 || (useradd -m -s /bin/bash $CHROOT_USER && echo '$CHROOT_USER:password' | chpasswd)"

# 4. Let the user select a Desktop Environment based on availability
echo
echo "Now let's determine available desktop meta-packages in the chroot and optionally install one."
DESKTOP_OPTIONS=(
  "GNOME (task-gnome-desktop / ubuntu-desktop)"
  "KDE/Plasma (task-kde-desktop / kde-standard)"
  "XFCE (task-xfce-desktop / xubuntu-desktop)"
  "LXDE (task-lxde-desktop / lubuntu-desktop)"
  "MATE (task-mate-desktop / ubuntu-mate-desktop)"
  "Cinnamon (cinnamon)"
  "None / Skip"
)

PS3="Select a desktop environment to install into the chroot (installation may be large): "
select de_choice in "${DESKTOP_OPTIONS[@]}"; do
  case "$de_choice" in
    "GNOME"*) DE_PKGS=("task-gnome-desktop" "ubuntu-desktop"); break ;;
    "KDE"*) DE_PKGS=("task-kde-desktop" "kde-standard" "kubuntu-desktop"); break ;;
    "XFCE"*) DE_PKGS=("task-xfce-desktop" "xubuntu-desktop" "xfce4"); break ;;
    "LXDE"*) DE_PKGS=("task-lxde-desktop" "lubuntu-desktop" "lxde"); break ;;
    "MATE"*) DE_PKGS=("task-mate-desktop" "ubuntu-mate-desktop" "mate-desktop-environment"); break ;;
    "Cinnamon"*) DE_PKGS=("cinnamon" "cinnamon-desktop-environment"); break ;;
    "None / Skip") DE_PKGS=(); break ;;
    *) echo "Invalid selection." ;;
  esac
done

if [ "${#DE_PKGS[@]}" -gt 0 ]; then
  # Find the first available package in the chroot apt.
  echo "Checking which desktop meta-package is available in the chroot..."
  AVAILABLE=""
  for p in "${DE_PKGS[@]}"; do
    if chroot_cmd "apt-cache show $p >/dev/null 2>&1"; then
      AVAILABLE="$p"
      break
    fi
  done

  if [ -z "$AVAILABLE" ]; then
    echo "No preferred desktop meta-package from the list seems available. You can still install using Synaptic later."
  else
    echo "The package '$AVAILABLE' is available. Installing it now (this may take a while)..."
    chroot_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y $AVAILABLE"
  fi
else
  echo "Skipping desktop package installation. You can install packages later from Synaptic."
fi

# 5. Open Synaptic and let the user pick/install packages
echo
echo "To run Synaptic inside the chroot so you can select additional packages graphically,"
echo "the script will allow the root user local X access temporarily."
echo
read -rp "Press ENTER to start Synaptic in the chroot (or Ctrl-C to cancel) ..."

# Allow local root X access, run synaptic inside chroot, then revoke access
# using xhost +SI:localuser:root is safer than xhost +
xhost +SI:localuser:root || echo "Warning: could not modify xhost permissions; if Synaptic fails to start, consider running 'xhost +SI:localuser:root' in host session."

# Try a few possible synaptic binary paths inside chroot
SYNAPTIC_PATHS=("/usr/sbin/synaptic" "/usr/bin/synaptic" "/usr/sbin/synaptic-pkexec")
SYNAPTIC_FOUND=""
for p in "${SYNAPTIC_PATHS[@]}"; do
  if chroot_cmd "[ -x $p ] && echo ok"; then
    SYNAPTIC_FOUND="$p"
    break
  fi
done

if [ -z "$SYNAPTIC_FOUND" ]; then
  echo "Synaptic binary not found inside chroot. Attempting to install again..."
  chroot_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y synaptic"
  if chroot_cmd "[ -x /usr/sbin/synaptic ] && echo ok"; then
    SYNAPTIC_FOUND="/usr/sbin/synaptic"
  else
    err "Synaptic still not available in chroot. Exiting."
  fi
fi

echo "Launching Synaptic in chroot (close Synaptic window to continue)..."
# Run synaptic as root inside the chroot. DISPLAY is inherited by chroot via environment replacement.
export DISPLAY="${DISPLAY:-:0}"
chroot "$CHROOT_DIR" /bin/bash -lc "export DISPLAY=${DISPLAY}; export TERM=${TERM:-xterm}; dbus-launch $SYNAPTIC_FOUND" || true

# Revoke X access
xhost -SI:localuser:root || true

echo "Synaptic closed (or returned). Proceeding to update the chroot."

# 6. After Synaptic closes, update and upgrade the chroot
echo "Updating and upgrading packages inside chroot..."
chroot_cmd "apt-get update"
chroot_cmd "DEBIAN_FRONTEND=noninteractive apt-get -y upgrade"
chroot_cmd "DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade || true"
chroot_cmd "DEBIAN_FRONTEND=noninteractive apt-get -y autoremove"
chroot_cmd "apt-get clean"

# 7. Copy the chroot to a raw disk image (EFI support)
echo
read -rp "Ready to create a raw disk image from the chroot for USB boot (size default ${IMAGE_SIZE}). Press ENTER to continue or Ctrl-C to cancel." tmp

read -rp "Enter image file path (default: ${IMAGE_FILE}): " input
IMAGE_FILE="${input:-$IMAGE_FILE}"

read -rp "Enter image size (e.g. 4G) default ${IMAGE_SIZE}: " input
IMAGE_SIZE="${input:-$IMAGE_SIZE}"

echo "Creating raw image ${IMAGE_FILE} of size ${IMAGE_SIZE}..."
qemu-img create -f raw "$IMAGE_FILE" "$IMAGE_SIZE"

# Associate loop device and partition
LOOPDEV=$(losetup --show -fP "$IMAGE_FILE")
if [ -z "$LOOPDEV" ]; then err "Failed to create loop device."; fi
echo "Loop device: $LOOPDEV"

# Partition: GPT, 1) EFI FAT32 512MiB, 2) ext4 root the rest
parted -s "$LOOPDEV" mklabel gpt
parted -s "$LOOPDEV" mkpart ESP fat32 1MiB 513MiB
parted -s "$LOOPDEV" set 1 boot on
parted -s "$LOOPDEV" mkpart primary ext4 513MiB 100%

# Wait for kernel to refresh partitions
sleep 1
# Partition device names: on modern systems it's e.g. /dev/loop0p1
PART1="${LOOPDEV}p1"
PART2="${LOOPDEV}p2"
if [ ! -b "$PART1" ]; then
  # fallback for systems that use /dev/loop0 (no 'p'), use kpartx to create
  kpartx -a "$LOOPDEV"
  sleep 1
  # list mapped devices
  MAPPEDS=$(ls /dev/mapper | grep "$(basename "$LOOPDEV" | sed 's/loop//')")
  PART1="/dev/mapper/$(basename "$LOOPDEV")p1" # attempt; this may vary
fi

# Format partitions
mkfs.vfat -F32 -n EFI "$PART1"
mkfs.ext4 -F -L ROOTFS "$PART2"

# Mount partitions
MNTDIR=$(mktemp -d)
mkdir -p "$MNTDIR/boot/efi"
mount "$PART2" "$MNTDIR"
mkdir -p "$MNTDIR/boot/efi"
mount "$PART1" "$MNTDIR/boot/efi"

# Rsync chroot to image rootfs
echo "Copying chroot filesystem to image root partition (this may take a while)..."
rsync -aAX --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} "$CHROOT_DIR/" "$MNTDIR/"

# Prepare for chroot into new image to install the bootloader (GRUB EFI)
for bd in dev dev/pts proc sys run; do
  mount --bind "/$bd" "$MNTDIR/$bd"
done

# Ensure /boot/efi exists and is mounted (we already mounted it)
# Install grub-efi-amd64 inside the image (chroot)
echo "Installing grub-efi inside the image chroot..."
chroot "$MNTDIR" /bin/bash -lc "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends grub-efi-amd64 shim-signed linux-image-amd64 || apt-get install -y --no-install-recommends grub-efi linux-image-amd64 || true"

# Attempt grub-install --removable to place grub in EFI/BOOT/BOOTX64.EFI
echo "Running grub-install (removable) ..."
chroot "$MNTDIR" /bin/bash -lc "grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable --recheck || true"
chroot "$MNTDIR" /bin/bash -lc "update-grub || true"

# Cleanup mounts
echo "Cleaning up mounts..."
for bd in dev/pts dev proc sys run; do
  umount -l "$MNTDIR/$bd" || true
done
umount -l "$MNTDIR/boot/efi" || true
umount -l "$MNTDIR" || true
losetup -d "$LOOPDEV" || true
kpartx -d "$LOOPDEV" || true
rmdir "$MNTDIR" || true

echo "Image $IMAGE_FILE created and (attempted) configured for EFI boot."
echo "You can dd this file to a USB device (be careful!):"
echo "  dd if=${IMAGE_FILE} of=/dev/sdX bs=4M status=progress oflag=sync"
echo
echo "Notes / Caveats:"
echo " - Installing a working bootloader inside an image can be tricky on some hosts."
echo " - If grub-install failed or the image does not boot on your target, you may need to"
echo "   chroot into the image on a system that supports EFI and re-run grub-install."
echo " - The image contains the packages you installed via Synaptic; further customization is possible."
echo
echo "Done."

# Unmount any leftover binds on the original chroot
umount_bind

exit 0
