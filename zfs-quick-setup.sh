#!/bin/bash
# Gentoo ZFS Root Interactive Installation Script
# 2025 Edition with Binary Kernel Support
# WARNING: This script will destroy data on the target disk!

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables
SCRIPT_VERSION="2.0"
STAGE3_ARCH="amd64"
STAGE3_PROFILE="openrc"  
GENTOO_MIRROR="https://distfiles.gentoo.org"

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

print_banner() {
    echo -e "${CYAN}"
    echo "=============================================="
    echo "  Gentoo ZFS Root Interactive Installer"
    echo "  Version: $SCRIPT_VERSION"
    echo "  Binary Kernel Edition"
    echo "=============================================="
    echo -e "${NC}"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Validate disk selection and ensure it's not mounted
validate_disk() {
    if [[ ! -b "$1" ]]; then
        print_error "Invalid disk: $1"
        return 1
    fi
    
    if mount | grep -q "$1"; then
        print_error "Disk $1 appears to be mounted. Please unmount before proceeding."
        return 1
    fi
    
    return 0
}

# Validate username format for system compliance
validate_username() {
    if [[ ! "$1" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        print_error "Invalid username. Must start with lowercase letter and contain only lowercase letters, numbers, hyphens, and underscores."
        return 1
    fi
    return 0
}

# =============================================================================
# NETWORK SETUP FUNCTIONS
# =============================================================================

check_internet() {
    print_status "Checking internet connectivity..."
    
    if ping -c 1 8.8.8.8 &>/dev/null; then
        print_success "Internet connectivity confirmed"
        return 0
    else
        print_warning "No internet connectivity detected"
        return 1
    fi
}

setup_network() {
    if ! check_internet; then
        print_warning "Internet connection required for installation"
        echo
        echo "Available network interfaces:"
        ip link show | grep -E "^[0-9]+:" | cut -d: -f2 | grep -v lo
        echo
        
        read -p "Would you like assistance setting up networking? (y/n): " setup_net
        
        if [[ "$setup_net" =~ ^[Yy] ]]; then
    echo
    echo "Network setup options:"
    echo "1) DHCP (automatic)"
    echo "2) Static IP"
    echo "3) WiFi setup"
    echo "4) Skip (configure manually)"
    
    read -p "Select option (1-4): " net_option
    
    case $net_option in
    1)
        read -p "Enter interface name (e.g., eth0, enp0s3): " interface
        print_status "Configuring DHCP on $interface..."
        dhcpcd "$interface"
        sleep 3
        ;;
    2)
        read -p "Enter interface name: " interface
        read -p "Enter IP address (e.g., 192.168.1.100/24): " ip_addr
        read -p "Enter gateway: " gateway
        read -p "Enter DNS server (default 8.8.8.8): " dns_server
        dns_server=${dns_server:-8.8.8.8}
        
        print_status "Configuring static IP..."
        ip addr add "$ip_addr" dev "$interface"
        ip link set "$interface" up
        ip route add default via "$gateway"
        echo "nameserver $dns_server" > /etc/resolv.conf
        ;;
    3)
        print_status "Available WiFi interfaces:"
        iw dev | grep Interface | cut -d' ' -f2
        read -p "Enter WiFi interface: " wifi_interface
        read -p "Enter SSID: " ssid
        read -s -p "Enter password: " wifi_pass
        echo
        
        print_status "Connecting to WiFi..."
        wpa_passphrase "$ssid" "$wifi_pass" > /etc/wpa_supplicant/wpa_supplicant.conf
        wpa_supplicant -B -i "$wifi_interface" -c /etc/wpa_supplicant/wpa_supplicant.conf
        dhcpcd "$wifi_interface"
        sleep 5
        ;;
    4)
        print_warning "Skipping network setup. Please configure manually if needed."
        ;;
    esac
    
    if ! check_internet; then
    print_error "Network setup failed. Please configure manually and re-run the script."
    exit 1
    fi
        else
    print_error "Internet connection required. Please configure networking and re-run."
    exit 1
        fi
    fi
}

# =============================================================================
# USER INPUT COLLECTION
# =============================================================================

collect_user_input() {
    print_banner
    
    echo "This script will install Gentoo Linux with ZFS root filesystem."
    echo "All data on the target disk will be destroyed!"
    echo
    
    # Disk selection with menu
    echo
    echo "=== Target Disk Selection ==="
    echo "Available disks:"
    
    # Get list of available disks
    mapfile -t AVAILABLE_DISKS < <(lsblk -d -n -o NAME,SIZE,MODEL | grep -v loop | awk '{print "/dev/" $1 " (" $2 " - " $3 ")"}')
    
    if [[ ${#AVAILABLE_DISKS[@]} -eq 0 ]]; then
        print_error "No suitable disks found"
        exit 1
    fi
    
    # Display disk menu
    for i in "${!AVAILABLE_DISKS[@]}"; do
        echo "$((i+1))) ${AVAILABLE_DISKS[i]}"
    done
    echo
    
    while true; do
        read -p "Select disk number (1-${#AVAILABLE_DISKS[@]}): " disk_choice
        if [[ "$disk_choice" =~ ^[0-9]+$ ]] && [[ "$disk_choice" -ge 1 ]] && [[ "$disk_choice" -le ${#AVAILABLE_DISKS[@]} ]]; then
            # Extract just the device path from the selection
            TARGET_DISK=$(echo "${AVAILABLE_DISKS[$((disk_choice-1))]}" | cut -d' ' -f1)
            break
        else
            print_error "Invalid selection. Please enter a number between 1 and ${#AVAILABLE_DISKS[@]}."
        fi
    done
    
    echo
    print_warning "Selected disk: $TARGET_DISK"
    lsblk "$TARGET_DISK"
    echo
    echo "WARNING: This will DESTROY ALL DATA on $TARGET_DISK"
    echo "Selected: ${AVAILABLE_DISKS[$((disk_choice-1))]}"
    echo
    read -p "Type 'DESTROY' to confirm (case sensitive): " confirm
    if [[ "$confirm" != "DESTROY" ]]; then
        print_error "Installation cancelled by user"
        exit 1
    fi
    
    echo
    read -p "Enable LUKS2 encryption? (recommended) (y/n): " use_encryption
    USE_ENCRYPTION=$([ "$use_encryption" = "y" ] && echo "true" || echo "false")
    
    echo
    echo "Swap options:"
    echo "1) zram (recommended for systems with 8GB+ RAM)"
    echo "2) Traditional disk swap"
    read -p "Select swap strategy (1-2): " swap_choice
    USE_ZRAM=$([ "$swap_choice" = "1" ] && echo "true" || echo "false")
    
    # User account configuration
    echo
    echo "=== User Account Setup ==="
    while true; do
        read -p "Enter username for new user: " USERNAME
        if validate_username "$USERNAME"; then
            break
        fi
    done
    
    # Root password setup
    echo
    echo "=== Root Password Setup ==="
    while true; do
        read -s -p "Enter root password: " ROOT_PASSWORD
        echo
        read -s -p "Confirm root password: " root_confirm
        echo
        if [[ "$ROOT_PASSWORD" = "$root_confirm" ]]; then
            break
        else
            print_error "Passwords do not match. Please try again."
        fi
    done
    print_success "Root password set"
    
    # User password setup
    echo
    echo "=== User Password Setup ($USERNAME) ==="
    while true; do
        read -s -p "Enter password for $USERNAME: " USER_PASSWORD
        echo
        read -s -p "Confirm password for $USERNAME: " user_confirm
        echo
        if [[ "$USER_PASSWORD" = "$user_confirm" ]]; then
            break
        else
            print_error "Passwords do not match. Please try again."
        fi
    done
    print_success "User password set for $USERNAME"
    
    echo
    echo "Setting timezone..."
    echo "Common timezones:"
    echo "  America/New_York"
    echo "  America/Chicago" 
    echo "  America/Denver"
    echo "  America/Los_Angeles"
    echo "  Europe/London"
    echo "  Europe/Paris"
    echo "  Asia/Tokyo"
    echo
    echo "Note: Minimal CD has limited timezone data. Valid format: Continent/City"
    
    # Check if we have a populated zoneinfo directory
    if [[ $(find /usr/share/zoneinfo -name "America" -type d 2>/dev/null | wc -l) -eq 0 ]]; then
        print_warning "Minimal CD detected - timezone validation disabled"
        read -p "Enter timezone (e.g., America/New_York): " TIMEZONE
        print_status "Timezone will be validated during chroot installation"
    else
        # Full validation available
        while true; do
            read -p "Enter timezone (e.g., America/New_York): " TIMEZONE
            if [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
                break
            else
                print_error "Invalid timezone. Please check /usr/share/zoneinfo/ for valid options."
            fi
        done
    fi
    
    echo
    echo "Common locales:"
    echo "  en_US.UTF-8"
    echo "  en_GB.UTF-8"
    echo "  de_DE.UTF-8"
    echo "  fr_FR.UTF-8"
    echo "  es_ES.UTF-8"
    echo
    read -p "Enter locale (default: en_US.UTF-8): " LOCALE
    LOCALE=${LOCALE:-en_US.UTF-8}
    
    echo
    read -p "Enter hostname (default: gentoo-zfs): " HOSTNAME
    HOSTNAME=${HOSTNAME:-gentoo-zfs}
    
    echo
    echo "Init system options:"
    echo "1) OpenRC "
    echo "2) systemd"
    read -p "Select init system (1-2, default: 1): " init_choice
    init_choice=${init_choice:-1}
    
    if [[ "$init_choice" = "2" ]]; then
        STAGE3_PROFILE="systemd"
        USE_SYSTEMD="true"
        print_status "Selected: systemd"
    else
        STAGE3_PROFILE="openrc"
        USE_SYSTEMD="false"
        print_status "Selected: OpenRC"
    fi
    
    echo
    echo "Video card options (select all that apply):"
    echo "1) Intel integrated graphics"
    echo "2) AMD/ATI graphics (open source)"
    echo "3) NVIDIA graphics"
    echo "4) VMware/VirtualBox (virtual machine)"
    echo "5) None/headless server"
    read -p "Enter selections separated by spaces (e.g., 1 3): " video_selections
    
    VIDEO_CARDS=""
    for selection in $video_selections; do
        case $selection in
    1) VIDEO_CARDS="$VIDEO_CARDS intel" ;;
    2) VIDEO_CARDS="$VIDEO_CARDS amdgpu radeon" ;;
    3) VIDEO_CARDS="$VIDEO_CARDS nvidia" ;;
    4) VIDEO_CARDS="$VIDEO_CARDS vmware" ;;
    5) VIDEO_CARDS="" ; break ;;
        esac
    done
    VIDEO_CARDS=$(echo "$VIDEO_CARDS" | xargs)  
    VIDEO_CARDS=${VIDEO_CARDS:-"intel amdgpu radeon nvidia"}  # Default fallback
    
    echo
    print_status "Installation Summary:"
    echo "Target Disk: $TARGET_DISK"
    echo "Encryption: $USE_ENCRYPTION"
    echo "Swap Strategy: $([ "$USE_ZRAM" = "true" ] && echo "zram" || echo "disk swap")"
    echo "Init System: $([ "$USE_SYSTEMD" = "true" ] && echo "systemd" || echo "OpenRC")"
    echo "Video Cards: ${VIDEO_CARDS:-"none/headless"}"
    echo "Username: $USERNAME"
    echo "Timezone: $TIMEZONE"
    echo "Locale: $LOCALE"
    echo "Hostname: $HOSTNAME"
    echo
    
    read -p "Proceed with installation? (yes/no): " final_confirm
    if [[ "$final_confirm" != "yes" ]]; then
        print_error "Installation cancelled by user"
        exit 1
    fi
}

# =============================================================================
# DISK PREPARATION FUNCTIONS
# =============================================================================

partition_disk() {
    print_status "Partitioning disk $TARGET_DISK..."
    
    umount "${TARGET_DISK}"* 2>/dev/null || true
    
    parted -s "$TARGET_DISK" mklabel gpt
    parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 513MiB
    parted -s "$TARGET_DISK" set 1 esp on
    
    # Determine partition naming scheme based on disk type
    if [[ "$TARGET_DISK" =~ nvme ]]; then
        EFI_PARTITION="${TARGET_DISK}p1"
        if [[ "$USE_ZRAM" = "false" ]]; then
            SWAP_PARTITION="${TARGET_DISK}p2"
            ZFS_PARTITION="${TARGET_DISK}p3"
        else
            SWAP_PARTITION=""  # No swap partition when using zram
            ZFS_PARTITION="${TARGET_DISK}p2"
        fi
    else
        EFI_PARTITION="${TARGET_DISK}1"
        if [[ "$USE_ZRAM" = "false" ]]; then
            SWAP_PARTITION="${TARGET_DISK}2"
            ZFS_PARTITION="${TARGET_DISK}3"
        else
            SWAP_PARTITION=""  # No swap partition when using zram
            ZFS_PARTITION="${TARGET_DISK}2"
        fi
    fi
    
    if [[ "$USE_ZRAM" = "true" ]]; then
        print_status "Creating zram layout (EFI + ZFS only)..."
        parted -s "$TARGET_DISK" mkpart primary 513MiB 100%
        print_success "zram layout: EFI (512MB) + ZFS (remaining space)"
    else
        print_status "Creating traditional swap layout (EFI + swap + ZFS)..."
        parted -s "$TARGET_DISK" mkpart primary linux-swap 513MiB 4609MiB
        parted -s "$TARGET_DISK" mkpart primary 4609MiB 100%
        print_success "Traditional layout: EFI (512MB) + swap (4GB) + ZFS (remaining space)"
    fi
    
    partprobe "$TARGET_DISK"
    sleep 2
    
    print_success "Disk partitioning complete"
}

# Format partitions according to the layout created during partitioning
format_partitions() {
    print_status "Formatting partitions..."
    
    mkfs.vfat -F 32 -s 1 "$EFI_PARTITION"
    print_success "EFI partition formatted"
    
    if [[ "$USE_ZRAM" = "true" ]]; then
        print_status "zram configuration - no disk swap partition to format"
    else
        print_status "Formatting and activating traditional swap partition..."
        mkswap "$SWAP_PARTITION"
        swapon "$SWAP_PARTITION"
        print_success "Traditional swap partition formatted and activated"
    fi
    
    print_success "Partition formatting complete"
}

setup_zfs() {
    print_status "Setting up ZFS..."
    
    modprobe zfs
    zgenhostid -f
    
    # Setup encryption if requested
    if [[ "$USE_ENCRYPTION" = "true" ]]; then
        print_status "Setting up LUKS2 encryption..."
        echo -n "$ROOT_PASSWORD" | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha256 --pbkdf argon2id "$ZFS_PARTITION" -
        
        echo -n "$ROOT_PASSWORD" | cryptsetup open "$ZFS_PARTITION" tank-crypt -
        ZFS_DEVICE="/dev/mapper/tank-crypt"
    else
        ZFS_DEVICE="$ZFS_PARTITION"
    fi
    
    print_status "Creating ZFS pool..."
    zpool create -f -o ashift=12 -o autotrim=on -o compatibility=openzfs-2.1-linux -R /mnt/gentoo -O acltype=posixacl -O xattr=sa -O relatime=on -O compression=zstd -O recordsize=1M -O dnodesize=auto -m none tank "$ZFS_DEVICE"
    
    print_status "Creating ZFS datasets..."
    zfs create -o mountpoint=none tank/ROOT
    zfs create -o mountpoint=/ -o canmount=noauto tank/ROOT/gentoo
    zfs create -o mountpoint=/home tank/home
    zfs create -o mountpoint=/var/log -o compression=gzip -o recordsize=64K tank/var-log
    zfs create -o mountpoint=/var/cache -o compression=lz4 -o recordsize=128K tank/var-cache
    zfs create -o mountpoint=/tmp -o compression=lz4 -o recordsize=128K -o setuid=off tank/tmp
    zpool set bootfs=tank/ROOT/gentoo tank
    
    print_success "ZFS setup complete"
}

mount_filesystems() {
    print_status "Mounting filesystems..."
    
    # Export and re-import pool
    zpool export tank
    zpool import -N -R /mnt/gentoo tank
    
    # Mount ZFS filesystems
    zfs mount tank/ROOT/gentoo
    zfs mount tank/home
    zfs mount tank/var-log
    zfs mount tank/var-cache
    zfs mount tank/tmp
    
    # Mount EFI partition
    mkdir -p /mnt/gentoo/efi
    mount "$EFI_PARTITION" /mnt/gentoo/efi
    
    # Copy host ID
    mkdir -p /mnt/gentoo/etc
    cp /etc/hostid /mnt/gentoo/etc/
    
    print_success "Filesystems mounted"
}

install_stage3() {
    print_status "Downloading and installing Gentoo stage3..."
    
    cd /mnt/gentoo
    
    # Smart mirror selection based on region
    print_status "Selecting optimal mirror for your region..."
    
    local mirrors_na=(
        "https://gentoo.osuosl.org/"
        "https://mirror.leaseweb.com/gentoo/"
        "https://mirrors.rit.edu/gentoo/"
        "https://distfiles.gentoo.org/"
    )
    
    local mirrors_eu=(
        "https://mirror.leaseweb.com/gentoo/"
        "https://mirrors.dotsrc.org/gentoo/"
        "https://ftp.fau.de/gentoo/"
        "https://distfiles.gentoo.org/"
    )
    
    # Use North America mirrors as default, could be made configurable
    local selected_mirrors=("${mirrors_na[@]}")
    
    # Function to test mirror and get current stage3
    get_current_stage3() {
        local mirror="$1"
        local latest_file="${mirror}releases/${STAGE3_ARCH}/autobuilds/latest-stage3-${STAGE3_ARCH}-${STAGE3_PROFILE}.txt"
        
        # Test connectivity with timeout (silently)
        if ! curl -s --connect-timeout 5 --max-time 10 "$latest_file" >/dev/null 2>&1; then
            return 1
        fi
        
        # Get and parse latest stage3 info
        local stage3_info=$(curl -s --max-time 15 "$latest_file" 2>/dev/null | grep -v '^#' | grep -v '^-----' | grep "\.tar\.xz" | head -n1)
        
        if [[ -n "$stage3_info" ]]; then
            local stage3_path=$(echo "$stage3_info" | awk '{print $1}')
            if [[ -n "$stage3_path" && "$stage3_path" =~ \.tar\.xz$ ]]; then
                echo "${mirror}releases/${STAGE3_ARCH}/autobuilds/${stage3_path}"
                return 0
            fi
        fi
        
        return 1
    }
    
    # Try mirrors until we find a working one
    STAGE3_DOWNLOAD_URL=""
    for mirror in "${selected_mirrors[@]}"; do
        print_status "Testing mirror: $mirror"
        if STAGE3_DOWNLOAD_URL=$(get_current_stage3 "$mirror"); then
            print_success "Found working mirror: $mirror"
            break
        else
            print_warning "Mirror failed: $mirror"
        fi
    done
    
    # Fallback to manual/hardcoded approach
    if [[ -z "$STAGE3_DOWNLOAD_URL" ]]; then
        print_warning "All mirrors failed. Using fallback method..."
        
        # Try to get from main Gentoo site with better parsing
        local latest_file="${GENTOO_MIRROR}/releases/${STAGE3_ARCH}/autobuilds/latest-stage3-${STAGE3_ARCH}-${STAGE3_PROFILE}.txt"
        print_status "Trying direct download from main Gentoo mirror..."
        
        # Download and show content for debugging
        if curl -s "$latest_file" > /tmp/latest-stage3-debug.txt; then
            print_status "Latest stage3 file content:"
            grep -v '^-----' /tmp/latest-stage3-debug.txt | head -5
            echo
            
            # Extract first valid line
            STAGE3_PATH=$(grep -v '^#' /tmp/latest-stage3-debug.txt | grep -v '^-----' | grep -v '^$' | head -n1 | awk '{print $1}')
            
            if [[ -n "$STAGE3_PATH" && "$STAGE3_PATH" =~ \.tar\.xz$ ]]; then
                STAGE3_DOWNLOAD_URL="${GENTOO_MIRROR}/releases/${STAGE3_ARCH}/autobuilds/${STAGE3_PATH}"
                print_status "Extracted stage3 URL: $STAGE3_DOWNLOAD_URL"
            else
                print_error "Could not parse stage3 URL from latest file"
                print_status "Manual entry required. Current known stage3:"
                echo "https://distfiles.gentoo.org/releases/amd64/autobuilds/20250706T150904Z/stage3-amd64-openrc-20250706T150904Z.tar.xz"
                exit 1
            fi
        else
            print_error "Could not fetch latest stage3 information"
            print_status "Using known working stage3 URL as fallback"
            STAGE3_DOWNLOAD_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/20250706T150904Z/stage3-amd64-${STAGE3_PROFILE}-20250706T150904Z.tar.xz"
        fi
    fi
    
    STAGE3_FILE=$(basename "$STAGE3_DOWNLOAD_URL")
    
    print_status "Will download: $STAGE3_FILE"
    print_status "From: $STAGE3_DOWNLOAD_URL"
    
    # Download with retry logic
    download_success=false
    for attempt in 1 2 3; do
        print_status "Download attempt $attempt of 3..."
        print_status "URL: $STAGE3_DOWNLOAD_URL"
        
        if command -v wget >/dev/null; then
            if wget --progress=bar:force --timeout=30 --tries=1 "$STAGE3_DOWNLOAD_URL" -O "$STAGE3_FILE" 2>/dev/null; then
                download_success=true
                break
            fi
        elif command -v curl >/dev/null; then
            if curl -L --progress-bar --connect-timeout 30 --max-time 300 -o "$STAGE3_FILE" "$STAGE3_DOWNLOAD_URL" 2>/dev/null; then
                download_success=true
                break
            fi
        fi
        
        if [[ $attempt -lt 3 ]]; then
            print_warning "Download failed, retrying in 3 seconds..."
            sleep 3
        fi
    done
    
    if [[ "$download_success" != "true" ]]; then
        print_error "Download failed after 3 attempts"
        print_status "Please manually download and place the stage3 file in /mnt/gentoo/"
        print_status "URL: $STAGE3_DOWNLOAD_URL"
        print_status "Manual command: wget '$STAGE3_DOWNLOAD_URL' -O '$STAGE3_FILE'"
        exit 1
    fi
    
    # Verify download
    if [[ ! -f "$STAGE3_FILE" ]]; then
        print_error "Downloaded file not found: $STAGE3_FILE"
        exit 1
    fi
    
    # Check file size and type
    local file_size=$(stat -c%s "$STAGE3_FILE" 2>/dev/null || stat -f%z "$STAGE3_FILE" 2>/dev/null || echo "0")
    print_status "Downloaded file size: $(( file_size / 1024 / 1024 ))MB"
    
    if [[ "$file_size" -lt 104857600 ]]; then  # 100MB
        print_warning "File seems small for a stage3 tarball"
        
        # Check if it's an HTML error page
        if file "$STAGE3_FILE" | grep -q "HTML"; then
            print_error "Downloaded file appears to be an HTML error page"
            head -5 "$STAGE3_FILE"
            rm -f "$STAGE3_FILE"
            exit 1
        fi
    fi
    
    # Verify it's a valid tar.xz file
    if ! file "$STAGE3_FILE" | grep -q -E "(XZ compressed|LZMA compressed)"; then
        print_error "Downloaded file is not a valid XZ compressed archive"
        print_status "File type: $(file "$STAGE3_FILE")"
        exit 1
    fi
    
    print_status "Extracting stage3 (this may take several minutes)..."
    if tar xpf "$STAGE3_FILE" --xattrs-include='*.*' --numeric-owner; then
        print_success "Stage3 extracted successfully"
        rm "$STAGE3_FILE"
        print_status "Cleaned up tarball"
        
        # Verify extraction
        print_status "Verifying extraction..."
        for dir in bin etc usr var; do
            if [[ -d "/mnt/gentoo/$dir" ]]; then
                print_success "✓ /$dir"
            else
                print_warning "✗ /$dir missing"
            fi
        done
    else
        print_error "Extraction failed"
        print_status "Tarball left at: $STAGE3_FILE"
        exit 1
    fi
    
    print_success "Stage3 installation complete"
}

# Configure Portage make.conf 
configure_make_conf() {
    print_status "Configuring make.conf..."
    
    cat >> /mnt/gentoo/etc/portage/make.conf << EOF

# ZFS and kernel configuration
USE="dist-kernel initramfs zfs"

# Optimization flags
MAKEOPTS="-j$(nproc)"
EMERGE_DEFAULT_OPTS="--jobs=$(nproc) --load-average=$(nproc)"

# Video cards
VIDEO_CARDS="$VIDEO_CARDS"

# Input devices
INPUT_DEVICES="libinput synaptics"

# Accept keywords for latest packages
# ACCEPT_KEYWORDS="~amd64"
EOF

    mkdir -p /mnt/gentoo/etc/portage/package.use
    cat > /mnt/gentoo/etc/portage/package.use/zfs << EOF
sys-kernel/installkernel dracut
sys-fs/zfs-kmod dist-kernel
sys-fs/zfs dist-kernel
EOF

    print_success "make.conf configuration complete"
}

setup_chroot() {
    print_status "Setting up chroot environment..."
    
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
    
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-slave /mnt/gentoo/run
    
    print_success "Chroot environment ready"
}

create_chroot_script() {
    print_status "Creating chroot configuration script..."
    
    cat > /mnt/gentoo/install-chroot.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# Source profile
source /etc/profile

# Update portage tree
emerge-webrsync

# Install ZFS
emerge -av sys-fs/zfs sys-fs/zfs-kmod

# Install binary kernel
emerge -av sys-kernel/gentoo-kernel-bin

# Configure dracut for ZFS
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/zfs.conf << 'DRACUT_EOF'
# ZFS support
add_dracutmodules+=" zfs "
nofsck="yes"

# Performance optimizations
compress="zstd"
hostonly="yes"
hostonly_cmdline="yes"

# Include recovery tools
install_items+=" /usr/bin/zpool /usr/bin/zfs "
DRACUT_EOF

# Add LUKS support if encryption is enabled
if [[ "$USE_ENCRYPTION" = "true" ]]; then
    echo 'add_dracutmodules+=" crypt "' >> /etc/dracut.conf.d/zfs.conf
    
    # Generate automatic unlock key
    dd if=/dev/urandom of=/etc/luks-key bs=1 count=4096
    chmod 600 /etc/luks-key
    echo -n "$ROOT_PASSWORD" | cryptsetup luksAddKey "$ZFS_PARTITION" /etc/luks-key -
    echo 'install_items+=" /etc/luks-key "' >> /etc/dracut.conf.d/zfs.conf
fi

# Rebuild initramfs
emerge --config sys-kernel/gentoo-kernel-bin

# Configure timezone with validation
if [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    echo "$TIMEZONE" > /etc/timezone
    emerge --config sys-libs/timezone-data
    echo "Timezone set to: $TIMEZONE"
else
    echo "Warning: Invalid timezone '$TIMEZONE' specified"
    echo "Available timezones in /usr/share/zoneinfo/"
    echo "Setting default timezone: UTC"
    echo "UTC" > /etc/timezone
    emerge --config sys-libs/timezone-data
    echo "You can change this later with: eselect timezone set <timezone>"
fi

# Configure locale
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set $(eselect locale list | grep "$LOCALE" | cut -d'[' -f2 | cut -d']' -f1)

# Set hostname
echo "$HOSTNAME" > /etc/hostname

# Configure fstab
cat > /etc/fstab << FSTAB_EOF
# EFI System Partition
$EFI_PARTITION    /efi    vfat    defaults,noatime    0 2

# tmpfs for /tmp
tmpfs        /tmp    tmpfs   defaults,noatime,mode=1777  0 0
FSTAB_EOF

# Add swap entry if using traditional swap
if [[ "$USE_ZRAM" = "false" ]]; then
    echo "$SWAP_PARTITION    none    swap    sw    0 0" >> /etc/fstab
fi

# Configure zram if selected
if [[ "$USE_ZRAM" = "true" ]]; then
    if [[ "$USE_SYSTEMD" = "true" ]]; then
        # systemd zram setup
        emerge -av sys-block/zram-generator
        
        cat > /etc/systemd/zram-generator.conf << 'ZRAM_EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
ZRAM_EOF
    else
        # OpenRC zram setup
        emerge -av sys-block/zram-init
        
        cat > /etc/conf.d/zram-init << 'ZRAM_EOF'
# zram settings for OpenRC
type0="swap"
size0="$(($(awk '/MemTotal/{print $2}' /proc/meminfo) / 2))K"
maxs0=1
algo0=zstd
ZRAM_EOF
    fi
fi

# Enable services based on init system
if [[ "$USE_SYSTEMD" = "true" ]]; then
    # systemd services
    systemctl enable zfs-import-cache
    systemctl enable zfs-mount
    systemctl enable zfs.target
    
    # Enable zram service if configured
    if [[ "$USE_ZRAM" = "true" ]]; then
        systemctl enable systemd-zram-setup@zram0.service
    fi
else
    # OpenRC services
    rc-update add zfs-import boot
    rc-update add zfs-mount boot
    rc-update add zfs-share default
    
    # Enable zram service if configured
    if [[ "$USE_ZRAM" = "true" ]]; then
        rc-update add zram-init boot
    fi
fi

# Install bootloader
emerge app-eselect/eselect-repository
eselect repository enable guru
emerge --sync
emerge -av sys-boot/zfsbootmenu

# Configure ZFSBootMenu
mkdir -p /etc/zfsbootmenu
cat > /etc/zfsbootmenu/config.yaml << 'ZBM_EOF'
Global:
  ManageImages: true
  BootMountPoint: /efi
  DracutConfDir: /etc/dracut.conf.d

Kernel:
  CommandLine: quiet loglevel=3 rd.systemd.show_status=auto

EFI:
  Enabled: true
  Stub: /usr/lib/systemd/boot/efi/linuxx64.efi.stub

UEFI:
  SecureBoot: false
ZBM_EOF

# Set kernel command line
zfs set org.zfsbootmenu:commandline="quiet loglevel=3 rd.systemd.show_status=auto" tank/ROOT

# Generate bootloader
generate-zbm

# Install efibootmgr
emerge -av sys-boot/efibootmgr

# Create dynamic boot entry script
cat > /usr/local/bin/update-zfs-bootentry << 'BOOT_EOF'
#!/bin/bash
HOSTNAME=$(hostname)
KERNEL_VER=$(uname -r)
BOOT_DISK=$(findmnt -n -o SOURCE /efi | sed 's/[0-9]*$//')
BOOT_PART=$(findmnt -n -o SOURCE /efi | sed 's/.*[^0-9]//')
BOOT_LABEL="${HOSTNAME}-${KERNEL_VER}"

if [ -f "/efi/EFI/ZBM/VMLINUZ.EFI" ]; then
    BOOT_PATH="\\EFI\\ZBM\\VMLINUZ.EFI"
elif [ -f "/efi/EFI/zbm/zfsbootmenu.EFI" ]; then
    BOOT_PATH="\\EFI\\zbm\\zfsbootmenu.EFI"
else
    echo "Error: No ZFSBootMenu binary found!"
    exit 1
fi

# Remove old entries
efibootmgr | grep "${HOSTNAME}" | cut -d'*' -f1 | cut -d't' -f2 | while read entry; do
    [ -n "$entry" ] && efibootmgr -b "$entry" -B
done

# Create new boot entry
efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "$BOOT_LABEL" -l "$BOOT_PATH"
BOOT_EOF

chmod +x /usr/local/bin/update-zfs-bootentry
/usr/local/bin/update-zfs-bootentry

# Create users
useradd -m -G users,wheel,audio,video -s /bin/bash "$USERNAME"

# Set passwords
echo "root:$ROOT_PASSWORD" | chpasswd
echo "$USERNAME:$USER_PASSWORD" | chpasswd

# Install and configure sudo
emerge -av app-admin/sudo
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Create recovery snapshots
zfs snapshot tank/ROOT/gentoo@install-complete
zfs snapshot tank/home@install-complete

echo "Chroot configuration complete!"
EOF

    # Make script executable and substitute variables
    chmod +x /mnt/gentoo/install-chroot.sh
    
    # Use here-doc to substitute variables
    sed -i "s|\$USE_ENCRYPTION|$USE_ENCRYPTION|g" /mnt/gentoo/install-chroot.sh
    sed -i "s|\$USE_ZRAM|$USE_ZRAM|g" /mnt/gentoo/install-chroot.sh
    sed -i "s|\$USE_SYSTEMD|$USE_SYSTEMD|g" /mnt/gentoo/install-chroot.sh
    sed -i "s|\$ROOT_PASSWORD|$ROOT_PASSWORD|g" /mnt/gentoo/install-chroot.sh
    sed -i "s|\$ZFS_PARTITION|$ZFS_PARTITION|g" /mnt/gentoo/install-chroot.sh
    sed -i "s|\$EFI_PARTITION|$EFI_PARTITION|g" /mnt/gentoo/install-chroot.sh
    sed -i "s|\$SWAP_PARTITION|${SWAP_PARTITION:-}|g" /mnt/gentoo/install-chroot.sh
    sed -i "s|\$TIMEZONE|$TIMEZONE|g" /mnt/gentoo/install-chroot.sh
    sed -i "s|\$LOCALE|$LOCALE|g" /mnt/gentoo/install-chroot.sh
    sed -i "s|\$HOSTNAME|$HOSTNAME|g" /mnt/gentoo/install-chroot.sh
    sed -i "s|\$USERNAME|$USERNAME|g" /mnt/gentoo/install-chroot.sh
    sed -i "s|\$USER_PASSWORD|$USER_PASSWORD|g" /mnt/gentoo/install-chroot.sh
    
    print_success "Chroot script created"
}

run_chroot_install() {
    print_status "Running chroot installation..."
    
    # Export variables for chroot
    export USE_ENCRYPTION USE_ZRAM USE_SYSTEMD ROOT_PASSWORD ZFS_PARTITION EFI_PARTITION TIMEZONE LOCALE HOSTNAME USERNAME USER_PASSWORD
    export SWAP_PARTITION="${SWAP_PARTITION:-}"  # May be empty when using zram
    
    chroot /mnt/gentoo /bin/bash /install-chroot.sh
    
    print_success "Chroot installation complete"
}

cleanup_and_finalize() {
    print_status "Cleaning up and finalizing installation..."
    
    # Remove chroot script
    rm -f /mnt/gentoo/install-chroot.sh
    
    # Update device links
    udevadm trigger
    
    print_success "Installation cleanup complete"
}

installation_complete() {
    print_success "Gentoo ZFS installation completed successfully!"
    echo
    print_status "Installation Summary:"
    echo "- System: Gentoo Linux with ZFS root filesystem"
    echo "- Kernel: Binary kernel (gentoo-kernel-bin)"
    echo "- Bootloader: ZFSBootMenu"
    echo "- Encryption: $([[ "$USE_ENCRYPTION" = "true" ]] && echo "LUKS2 enabled" || echo "Disabled")"
    echo "- Swap: $([[ "$USE_ZRAM" = "true" ]] && echo "zram" || echo "Traditional disk swap")"
    echo "- User: $USERNAME"
    echo "- Hostname: $HOSTNAME"
    echo
    print_status "Next steps:"
    echo "1. Exit the chroot environment"
    echo "2. Unmount filesystems"
    echo "3. Export ZFS pool"
    echo "4. Reboot into new system"
    echo
    
    read -p "Would you like to reboot now? (y/n): " reboot_now
    
    if [[ "$reboot_now" =~ ^[Yy] ]]; then
        print_status "Preparing for reboot..."
        
        # Unmount filesystems
        cd /
        umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
        umount -R /mnt/gentoo 2>/dev/null || true
        
        # Export ZFS pool
        zpool export tank
        
        print_success "System ready for reboot"
        sleep 2
        reboot
    else
        print_status "Manual cleanup required:"
        echo "cd /"
        echo "umount -l /mnt/gentoo/dev{/shm,/pts,}"
        echo "umount -R /mnt/gentoo"
        echo "zpool export tank"
        echo "reboot"
    fi
}

# Main installation function
main() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
    
    # Setup network connectivity
    setup_network
    
    # Collect user input
    collect_user_input
    
    # Installation steps
    partition_disk
    format_partitions
    setup_zfs
    mount_filesystems
    install_stage3
    configure_make_conf
    setup_chroot
    create_chroot_script
    run_chroot_install
    cleanup_and_finalize
    installation_complete
}

# Error handler
trap 'print_error "Installation failed at line $LINENO. Check the error messages above."' ERR

# Run main installation
main "$@"
