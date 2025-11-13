#!/bin/bash

# Custom Distro Builder Script
# This script creates a custom Debian/Ubuntu distribution with user-selected packages

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        print_error "This script should not be run as root. Run as regular user."
        exit 1
    fi
}

# Function to install necessary packages
install_dependencies() {
    print_status "Installing necessary packages..."
    
    # Check if we're on Debian/Ubuntu
    if ! command -v apt-get &> /dev/null; then
        print_error "This script requires Debian/Ubuntu based system"
        exit 1
    fi
    
    # Update package list
    sudo apt-get update
    
    # Install required packages
    sudo apt-get install -y \
        debootstrap \
        schroot \
        squashfs-tools \
        genisoimage \
        syslinux-utils \
        mtools \
        dosfstools \
        grub-efi-amd64-bin \
        grub-pc-bin \
        xorriso
    
    print_success "Dependencies installed successfully"
}

# Function to select distribution
select_distribution() {
    echo ""
    echo "=== Distribution Selection ==="
    echo "1. Ubuntu (Latest LTS)"
    echo "2. Debian (Latest Stable)"
    echo ""
    
    while true; do
        read -p "Select distribution (1-2): " distro_choice
        case $distro_choice in
            1)
                DISTRO="ubuntu"
                SUITE="jammy"  # Ubuntu 22.04 LTS
                MIRROR="http://archive.ubuntu.com/ubuntu/"
                print_status "Selected: Ubuntu 22.04 LTS (Jammy)"
                break
                ;;
            2)
                DISTRO="debian"
                SUITE="bullseye"  # Debian 11
                MIRROR="http://deb.debian.org/debian/"
                print_status "Selected: Debian 11 (Bullseye)"
                break
                ;;
            *)
                print_error "Invalid choice. Please select 1 or 2."
                ;;
        esac
    done
}

# Function to select desktop environment
select_desktop_environment() {
    echo ""
    echo "=== Desktop Environment Selection ==="
    
    if [[ "$DISTRO" == "ubuntu" ]]; then
        echo "Available Desktop Environments:"
        echo "1. GNOME (Default Ubuntu desktop)"
        echo "2. KDE Plasma"
        echo "3. XFCE"
        echo "4. LXQt"
        echo "5. MATE"
        echo "6. None (Minimal system)"
        echo ""
        
        while true; do
            read -p "Select desktop environment (1-6): " de_choice
            case $de_choice in
                1)
                    DESKTOP_PACKAGE="ubuntu-desktop"
                    DESKTOP_NAME="GNOME"
                    break
                    ;;
                2)
                    DESKTOP_PACKAGE="kde-plasma-desktop"
                    DESKTOP_NAME="KDE Plasma"
                    break
                    ;;
                3)
                    DESKTOP_PACKAGE="xfce4"
                    DESKTOP_NAME="XFCE"
                    break
                    ;;
                4)
                    DESKTOP_PACKAGE="lxqt"
                    DESKTOP_NAME="LXQt"
                    break
                    ;;
                5)
                    DESKTOP_PACKAGE="ubuntu-mate-desktop"
                    DESKTOP_NAME="MATE"
                    break
                    ;;
                6)
                    DESKTOP_PACKAGE=""
                    DESKTOP_NAME="None"
                    break
                    ;;
                *)
                    print_error "Invalid choice. Please select 1-6."
                    ;;
            esac
        done
    else  # Debian
        echo "Available Desktop Environments:"
        echo "1. GNOME"
        echo "2. KDE Plasma"
        echo "3. XFCE"
        echo "4. LXDE"
        echo "5. MATE"
        echo "6. Cinnamon"
        echo "7. None (Minimal system)"
        echo ""
        
        while true; do
            read -p "Select desktop environment (1-7): " de_choice
            case $de_choice in
                1)
                    DESKTOP_PACKAGE="task-gnome-desktop"
                    DESKTOP_NAME="GNOME"
                    break
                    ;;
                2)
                    DESKTOP_PACKAGE="task-kde-desktop"
                    DESKTOP_NAME="KDE Plasma"
                    break
                    ;;
                3)
                    DESKTOP_PACKAGE="task-xfce-desktop"
                    DESKTOP_NAME="XFCE"
                    break
                    ;;
                4)
                    DESKTOP_PACKAGE="task-lxde-desktop"
                    DESKTOP_NAME="LXDE"
                    break
                    ;;
                5)
                    DESKTOP_PACKAGE="task-mate-desktop"
                    DESKTOP_NAME="MATE"
                    break
                    ;;
                6)
                    DESKTOP_PACKAGE="task-cinnamon-desktop"
                    DESKTOP_NAME="Cinnamon"
                    break
                    ;;
                7)
                    DESKTOP_PACKAGE=""
                    DESKTOP_NAME="None"
                    break
                    ;;
                *)
                    print_error "Invalid choice. Please select 1-7."
                    ;;
            esac
        done
    fi
    
    print_status "Selected: $DESKTOP_NAME"
}

# Function to debootstrap the system
debootstrap_system() {
    print_status "Creating chroot directory..."
    CHROOT_DIR="$(pwd)/${DISTRO}_chroot"
    
    if [[ -d "$CHROOT_DIR" ]]; then
        print_warning "Chroot directory already exists. Removing..."
        sudo rm -rf "$CHROOT_DIR"
    fi
    
    print_status "Debootstrapping $DISTRO $SUITE..."
    sudo debootstrap --arch=amd64 "$SUITE" "$CHROOT_DIR" "$MIRROR"
    
    if [[ $? -eq 0 ]]; then
        print_success "Debootstrap completed successfully"
    else
        print_error "Debootstrap failed"
        exit 1
    fi
}

# Function to configure chroot
configure_chroot() {
    print_status "Configuring chroot environment..."
    
    # Copy resolv.conf for network access
    sudo cp /etc/resolv.conf "$CHROOT_DIR/etc/"
    
    # Set up sources.list
    if [[ "$DISTRO" == "ubuntu" ]]; then
        sudo tee "$CHROOT_DIR/etc/apt/sources.list" > /dev/null <<EOF
deb http://archive.ubuntu.com/ubuntu/ $SUITE main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $SUITE-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $SUITE-security main restricted universe multiverse
EOF
    else
        sudo tee "$CHROOT_DIR/etc/apt/sources.list" > /dev/null <<EOF
deb http://deb.debian.org/debian/ $SUITE main contrib non-free
deb http://deb.debian.org/debian/ $SUITE-updates main contrib non-free
deb http://security.debian.org/debian-security $SUITE-security main contrib non-free
EOF
    fi
    
    # Mount necessary filesystems
    sudo mount --bind /proc "$CHROOT_DIR/proc"
    sudo mount --bind /sys "$CHROOT_DIR/sys"
    sudo mount --bind /dev "$CHROOT_DIR/dev"
    sudo mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
}

# Function to install base system
install_base_system() {
    print_status "Installing base system in chroot..."
    
    # Update package lists
    sudo chroot "$CHROOT_DIR" apt-get update
    
    # Install essential packages
    sudo chroot "$CHROOT_DIR" apt-get install -y \
        sudo \
        locales \
        keyboard-configuration \
        console-setup \
        network-manager \
        dbus-x11 \
        pulseaudio
    
    # Set locale
    sudo chroot "$CHROOT_DIR" locale-gen en_US.UTF-8
    sudo chroot "$CHROOT_DIR" update-locale LANG=en_US.UTF-8
    
    # Install Synaptic
    print_status "Installing Synaptic..."
    sudo chroot "$CHROOT_DIR" apt-get install -y synaptic
    
    # Install selected desktop environment
    if [[ -n "$DESKTOP_PACKAGE" ]]; then
        print_status "Installing $DESKTOP_NAME desktop environment..."
        sudo chroot "$CHROOT_DIR" apt-get install -y "$DESKTOP_PACKAGE"
    fi
    
    # Install additional useful packages
    sudo chroot "$CHROOT_DIR" apt-get install -y \
        firefox-esr \
        file-manager \
        text-editor \
        terminal
    
    print_success "Base system installation completed"
}

# Function to run Synaptic for package selection
run_synaptic() {
    print_status "Starting Synaptic for package selection..."
    echo ""
    echo "=== Synaptic Package Manager ==="
    echo "You can now use Synaptic to select additional packages."
    echo "When you're done, close Synaptic to continue."
    echo ""
    
    # Set up X11 forwarding for GUI applications
    export DISPLAY=:0
    
    # Run Synaptic in chroot (requires X11 forwarding)
    if command -v xhost &> /dev/null; then
        xhost +local:root > /dev/null 2>&1
        sudo chroot "$CHROOT_DIR" synaptic
        xhost -local:root > /dev/null 2>&1
    else
        print_warning "X11 not available. Cannot run Synaptic GUI."
        print_status "You can manually install packages using apt in the chroot."
        echo ""
        echo "To manually install packages, run:"
        echo "  sudo chroot $CHROOT_DIR apt install <package-name>"
        echo ""
        read -p "Press Enter to continue without Synaptic..."
    fi
}

# Function to update chroot
update_chroot() {
    print_status "Updating chroot system..."
    
    sudo chroot "$CHROOT_DIR" apt-get update
    sudo chroot "$CHROOT_DIR" apt-get upgrade -y
    sudo chroot "$CHROOT_DIR" apt-get autoremove -y
    sudo chroot "$CHROOT_DIR" apt-get clean
    
    print_success "Chroot updated successfully"
}

# Function to create bootable USB image
create_bootable_image() {
    print_status "Creating bootable USB image..."
    
    IMAGE_NAME="${DISTRO}_custom_$(date +%Y%m%d_%H%M%S).img"
    IMAGE_SIZE="4G"  # 4GB image size
    
    # Create disk image
    print_status "Creating disk image file: $IMAGE_NAME"
    dd if=/dev/zero of="$IMAGE_NAME" bs=1M count=$((4 * 1024)) status=progress
    
    # Partition the image
    print_status "Partitioning disk image..."
    parted "$IMAGE_NAME" mklabel gpt
    parted "$IMAGE_NAME" mkpart primary fat32 1MiB 513MiB
    parted "$IMAGE_NAME" set 1 esp on
    parted "$IMAGE_NAME" mkpart primary ext4 513MiB 100%
    
    # Set up loop device
    LOOP_DEV=$(sudo losetup --find --show --partscan "$IMAGE_NAME")
    
    # Format partitions
    print_status "Formatting partitions..."
    sudo mkfs.fat -F32 "${LOOP_DEV}p1"
    sudo mkfs.ext4 "${LOOP_DEV}p2"
    
    # Mount partitions
    print_status "Mounting partitions..."
    MOUNT_DIR="/mnt/custom_distro"
    sudo mkdir -p "$MOUNT_DIR"
    sudo mount "${LOOP_DEV}p2" "$MOUNT_DIR"
    sudo mkdir -p "$MOUNT_DIR/boot/efi"
    sudo mount "${LOOP_DEV}p1" "$MOUNT_DIR/boot/efi"
    
    # Copy chroot to image
    print_status "Copying system to disk image..."
    sudo cp -a "$CHROOT_DIR/"* "$MOUNT_DIR/"
    
    # Install bootloader
    print_status "Installing GRUB bootloader..."
    sudo chroot "$MOUNT_DIR" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$DISTRO" --recheck
    sudo chroot "$MOUNT_DIR" update-grub
    
    # Configure fstab
    print_status "Configuring fstab..."
    sudo tee "$MOUNT_DIR/etc/fstab" > /dev/null <<EOF
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=$(sudo blkid -s UUID -o value "${LOOP_DEV}p1") /boot/efi vfat umask=0077 0 1
UUID=$(sudo blkid -s UUID -o value "${LOOP_DEV}p2") / ext4 errors=remount-ro 0 1
EOF
    
    # Clean up
    print_status "Cleaning up..."
    sudo umount "$MOUNT_DIR/boot/efi"
    sudo umount "$MOUNT_DIR"
    sudo losetup -d "$LOOP_DEV"
    
    print_success "Bootable USB image created: $IMAGE_NAME"
}

# Function to clean up
cleanup() {
    print_status "Cleaning up..."
    
    # Unmount filesystems
    if mountpoint -q "$CHROOT_DIR/proc"; then
        sudo umount "$CHROOT_DIR/proc"
    fi
    if mountpoint -q "$CHROOT_DIR/sys"; then
        sudo umount "$CHROOT_DIR/sys"
    fi
    if mountpoint -q "$CHROOT_DIR/dev/pts"; then
        sudo umount "$CHROOT_DIR/dev/pts"
    fi
    if mountpoint -q "$CHROOT_DIR/dev"; then
        sudo umount "$CHROOT_DIR/dev"
    fi
    
    print_success "Cleanup completed"
}

# Main execution
main() {
    echo ""
    echo "========================================"
    echo "    Custom Distro Builder Script"
    echo "========================================"
    echo ""
    
    # Check if running as root
    check_root
    
    # Step 0: Install dependencies
    install_dependencies
    
    # Step 1: Select distribution
    select_distribution
    
    # Step 2: Debootstrap system
    debootstrap_system
    
    # Step 3: Configure chroot
    configure_chroot
    
    # Step 4: Install base system and Synaptic
    install_base_system
    
    # Step 5: Select desktop environment
    select_desktop_environment
    
    # Step 6: Run Synaptic for package selection
    run_synaptic
    
    # Step 7: Update chroot
    update_chroot
    
    # Step 8: Create bootable USB image
    create_bootable_image
    
    # Cleanup
    cleanup
    
    echo ""
    echo "========================================"
    echo "    Build Process Completed!"
    echo "========================================"
    echo ""
    echo "Your custom $DISTRO distribution with $DESKTOP_NAME is ready!"
    echo "Bootable image: $(pwd)/${DISTRO}_custom_*.img"
    echo ""
    echo "To write to USB drive, use:"
    echo "  sudo dd if=${DISTRO}_custom_*.img of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "Replace /dev/sdX with your USB device (be careful!)"
    echo ""
}

# Handle script interruption
trap cleanup EXIT

# Run main function
main "$@"
