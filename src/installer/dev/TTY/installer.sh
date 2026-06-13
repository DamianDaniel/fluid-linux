#!/bin/bash

RED='\033[0;31m'
GRN='\033[0;32m'
CYN='\033[0;36m'
YEL='\033[1;33m'
BLD='\033[1m'
RST='\033[0m'

EXTRA_USERS=()
DE_CHOICE=""
SHELL_CHOICE=""
NET_TYPE=""

die() { echo -e "${RED}ERROR: $1${RST}" >&2; cleanup; exit 1; }

banner() {
    clear
    echo -e "${CYN}${BLD}"
    cat <<'ART'
  ____                       _  ___  ____
 | __ )  ___  _ __ ___  __ _| |/ _ \/ ___|
 |  _ \ / _ \| '__/ _ \/ _` | | | | \___ \
 | |_) | (_) | | |  __/ (_| | | |_| |___) |
 |____/ \___/|_|  \___|\__,_|_|\___/|____/
ART
    echo -e "${RST}"
}

ask() {
    local prompt="$1" var="$2" default="$3"
    while true; do
        echo -ne "${CYN}${prompt}${RST}"
        [ -n "$default" ] && echo -ne " [${default}]"
        echo -ne ": "
        read -r input
        input="${input:-$default}"
        [ -n "$input" ] && { printf -v "$var" '%s' "$input"; return; }
        echo -e "${RED}Cannot be empty.${RST}"
    done
}

ask_pass() {
    local prompt="$1" var="$2"
    while true; do
        echo -ne "${CYN}${prompt}${RST} (doesn't echo): "
        read -rs p1; echo
        echo -ne "${CYN}Confirm ${prompt}${RST} (doesn't echo): "
        read -rs p2; echo
        if [ -n "$p1" ] && [ "$p1" = "$p2" ]; then
            printf -v "$var" '%s' "$p1"
            return
        fi
        echo -e "${RED}Passwords do not match or are empty. Try again.${RST}"
    done
}

menu() {
    local title="$1"; shift
    local options=("$@")
    echo -e "${BLD}${title}${RST}"
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[$i]}"
    done
    while true; do
        echo -ne "${CYN}Choice${RST}: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            MENU_RESULT="${options[$((choice-1))]}"
            return
        fi
        echo -e "${RED}Invalid.${RST}"
    done
}

confirm() {
    echo -ne "${CYN}$1 [y/N]${RST}: "
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

check_root() {
    [ "$EUID" -eq 0 ] || die "Run as root."
}

select_disk() {
    banner
    echo -e "${BLD}Available disks:${RST}"
    echo
    lsblk -dpno NAME,SIZE,MODEL | grep -v "loop\|sr0"
    echo
    ask "Target disk (e.g. /dev/sda)" DISK
    [ -b "$DISK" ] || die "$DISK is not a block device."
    echo -e "${RED}${BLD}WARNING: All data on $DISK will be destroyed.${RST}"
    confirm "Continue?" || die "Aborted."
}

partition_disk() {
    banner
    echo -e "${BLD}Partitioning $DISK...${RST}"
    parted -s "$DISK" mklabel gpt || die "Failed to create GPT label"
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB || die "Failed to create EFI partition"
    parted -s "$DISK" set 1 esp on || die "Failed to set ESP flag"
    parted -s "$DISK" mkpart primary ext4 513MiB 100% || die "Failed to create root partition"
    
    if [[ "$DISK" == *nvme* ]]; then
        EFI="${DISK}p1"; ROOT="${DISK}p2"
    else
        EFI="${DISK}1"; ROOT="${DISK}2"
    fi
    
    # Verify partitions exist
    sleep 1  # Give kernel time to register new partitions
    [ -b "$EFI" ] || die "EFI partition $EFI not found"
    [ -b "$ROOT" ] || die "Root partition $ROOT not found"
    
    echo "Formatting EFI partition ($EFI)..."
    mkfs.fat -F32 -n EFI "$EFI" || die "Failed to format EFI partition"
    
    echo "Formatting root partition ($ROOT)..."
    mkfs.ext4 -F -L borealOS "$ROOT" || die "Failed to format root partition"
    
    echo -e "${GRN}Partitioning complete.${RST}"
}

mount_target() {
    banner
    echo -e "${BLD}Mounting target filesystems...${RST}"
    
    echo "Mounting root filesystem ($ROOT at /mnt)..."
    mount "$ROOT" /mnt || die "Failed to mount root filesystem"
    [ -d /mnt ] || die "Mount verification failed"
    
    mkdir -p /mnt/boot/efi
    echo "Mounting EFI filesystem ($EFI at /mnt/boot/efi)..."
    mount "$EFI" /mnt/boot/efi || die "Failed to mount EFI filesystem"
    
    echo -e "${GRN}Filesystems mounted successfully.${RST}"
}

install_rootfs() {
    banner
    echo -e "${BLD}Installing base system...${RST}"
    [ -f /opt/borealOS/rootfs.tar.gz ] || die "Rootfs not found at /opt/borealOS/rootfs.tar.gz"
    
    echo "Extracting rootfs to $ROOT..."
    tar -xzf /opt/borealOS/rootfs.tar.gz -C /mnt || die "Failed to extract rootfs"
    
    # Verify extraction worked
    [ -d /mnt/etc ] || die "Rootfs extraction failed (no /etc directory)"
    [ -d /mnt/bin ] || die "Rootfs extraction failed (no /bin directory)"
    
    echo -e "${GRN}Rootfs extracted successfully.${RST}"
}

select_de() {
    banner
    menu "Select desktop environment / window manager:" "KDE Plasma" "XFCE" "Sway (Wayland)" "None (TTY only)"
    DE_CHOICE="$MENU_RESULT"
}

select_shell() {
    banner
    menu "Select default shell:" "bash" "fish" "sh"
    SHELL_CHOICE="$MENU_RESULT"
}

select_timezone() {
    banner
    echo -e "${BLD}Timezone selection${RST}"
    echo "Type part of a timezone name to filter (e.g. 'Europe', 'Berlin', 'US')."
    echo "Leave blank to list all."
    echo
    echo -ne "${CYN}Filter${RST}: "
    read -r tz_filter

    mapfile -t tz_list < <(find /usr/share/zoneinfo -type f | sed 's|/usr/share/zoneinfo/||' | grep -v "^posix\|^right\|\.tab$\|^leap" | sort | grep -i "${tz_filter}")

    if [ ${#tz_list[@]} -eq 0 ]; then
        echo -e "${RED}No matches. Enter manually.${RST}"
        ask "Timezone" TIMEZONE "UTC"
        return
    fi

    if [ ${#tz_list[@]} -gt 40 ]; then
        echo -e "${RED}${#tz_list[@]} results. Refine your filter.${RST}"
        select_timezone
        return
    fi

    for i in "${!tz_list[@]}"; do
        echo "  $((i+1))) ${tz_list[$i]}"
    done
    echo
    while true; do
        echo -ne "${CYN}Choice (0 = enter manually)${RST}: "
        read -r choice
        if [ "$choice" = "0" ]; then
            ask "Timezone" TIMEZONE "UTC"
            return
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#tz_list[@]} )); then
            TIMEZONE="${tz_list[$((choice-1))]}"
            return
        fi
        echo -e "${RED}Invalid.${RST}"
    done
}

get_user_info() {
    banner
    ask "Hostname" HOSTNAME "borealOS"
    ask_pass "Root password" ROOT_PASS
    ask "Locale (e.g. en_US.UTF-8)" LOCALE "en_US.UTF-8"
    select_timezone
}

get_extra_users() {
    banner
    echo -e "${BLD}Extra user accounts${RST}"
    echo "Leave username blank to stop."
    echo
    while true; do
        echo -ne "${CYN}Username (blank to stop)${RST}: "
        read -r uname
        [ -z "$uname" ] && break
        ask_pass "Password for $uname" upass
        EXTRA_USERS+=("${uname}|${upass}")
        echo -e "${GRN}Added: $uname${RST}"
    done
}

configure_network() {
    banner
    menu "Network configuration:" "DHCP (automatic)" "Static IP" "Skip (configure later)"
    NET_TYPE="$MENU_RESULT"

    if [ "$NET_TYPE" = "Skip (configure later)" ]; then
        return
    fi

    echo
    echo -e "${BLD}Available interfaces:${RST}"
    ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print "  "$2}' | grep -v lo
    echo
    ask "Network interface" NET_IF "eth0"

    if [ "$NET_TYPE" = "Static IP" ]; then
        ask "IP address with prefix (e.g. 192.168.1.100/24)" NET_IP
        ask "Gateway" NET_GW
        ask "DNS" NET_DNS "1.1.1.1"
    fi
}

chroot_install() {
    banner
    echo -e "${BLD}Configuring installed system (chroot)...${RST}"

    # Bind critical filesystems (order matters!)
    echo "Binding system filesystems..."
    for d in dev proc sys run; do mount --bind /$d /mnt/$d || die "Failed to bind /$d"; done
    cp /etc/resolv.conf /mnt/etc/resolv.conf || echo "Warning: resolv.conf copy failed"

    # Get UUID of root partition for fstab
    echo "Getting partition UUIDs..."
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT") || die "Failed to get root UUID"
    EFI_UUID=$(blkid -s UUID -o value "$EFI") || die "Failed to get EFI UUID"
    
    echo "Root UUID: $ROOT_UUID"
    echo "EFI UUID: $EFI_UUID"

    case "$DE_CHOICE" in
        "KDE Plasma")     DE_PKGS="kde-plasma-desktop sddm" ;;
        "XFCE")           DE_PKGS="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter" ;;
        "Sway (Wayland)") DE_PKGS="sway swaybar swaybg swaylock waybar foot" ;;
        *)                DE_PKGS="" ;;
    esac

    case "$SHELL_CHOICE" in
        fish) SHELL_PKG="fish"; SHELL_BIN="/usr/bin/fish" ;;
        sh)   SHELL_PKG="";    SHELL_BIN="/bin/sh" ;;
        *)    SHELL_PKG="";    SHELL_BIN="/bin/bash" ;;
    esac

    USERS_SCRIPT=""
    for entry in "${EXTRA_USERS[@]}"; do
        uname="${entry%%|*}"
        upass="${entry##*|}"
        # Create user without groups first (they may not exist in minimal rootfs)
        USERS_SCRIPT+="useradd -m -s ${SHELL_BIN} ${uname} 2>/dev/null || true"$'\n'
        # Try to add to groups if they exist
        USERS_SCRIPT+="for group in sudo audio video netdev; do getent group \$group >/dev/null 2>&1 && usermod -aG \$group ${uname} 2>/dev/null || true; done"$'\n'
        # Set password safely
        USERS_SCRIPT+="echo \"${uname}:${upass}\" | chpasswd 2>/dev/null || echo \"Warning: password set failed for ${uname}\""$'\n'
    done

    NET_SCRIPT=""
    if [ "$NET_TYPE" = "DHCP (automatic)" ]; then
        NET_SCRIPT="mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/${NET_IF}.nmconnection <<NMC
[connection]
id=${NET_IF}
type=ethernet
interface-name=${NET_IF}
[ipv4]
method=auto
[ipv6]
method=auto
NMC
chmod 600 /etc/NetworkManager/system-connections/${NET_IF}.nmconnection"
    elif [ "$NET_TYPE" = "Static IP" ]; then
        NET_SCRIPT="mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/${NET_IF}.nmconnection <<NMC
[connection]
id=${NET_IF}
type=ethernet
interface-name=${NET_IF}
[ipv4]
method=manual
addresses=${NET_IP}
gateway=${NET_GW}
dns=${NET_DNS}
[ipv6]
method=auto
NMC
chmod 600 /etc/NetworkManager/system-connections/${NET_IF}.nmconnection"
    fi

    echo "Running chroot configuration..."
    chroot /mnt /bin/sh <<'CHROOT'
# Minimal sh script - no fancy features
set +e  # Continue on errors

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
HOSTS

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
echo "$TIMEZONE" > /etc/timezone

# Try to generate locales if available
if [ -f /etc/locale.gen ] && command -v locale-gen >/dev/null 2>&1; then
    if grep -q "^#.*$LOCALE" /etc/locale.gen 2>/dev/null; then
        sed -i "s/^#.*$LOCALE/$LOCALE/" /etc/locale.gen
    else
        echo "$LOCALE UTF-8" >> /etc/locale.gen
    fi
    locale-gen 2>&1 || echo "Warning: locale-gen failed"
fi
echo "LANG=$LOCALE" > /etc/locale.conf

# Create fstab
cat > /etc/fstab <<FSTAB
UUID=$ROOT_UUID  /     ext4  defaults,relatime  0  1
UUID=$EFI_UUID   /boot/efi  vfat  defaults,relatime  0  2
FSTAB

cat > /etc/os-release <<OS
NAME="BorealOS"
PRETTY_NAME="BorealOS 1.0"
ID=borealos
ID_LIKE=
VERSION="1.0"
VERSION_ID="1.0"
HOME_URL="https://borealos.org"
SUPPORT_URL="https://borealos.org"
BUG_REPORT_URL="https://borealos.org"
OS

cat > /etc/lsb-release <<LSB
DISTRIB_ID=BorealOS
DISTRIB_RELEASE=1.0
DISTRIB_CODENAME=boreal
DISTRIB_DESCRIPTION="BorealOS 1.0"
LSB

echo "BorealOS"     > /etc/issue
echo "BorealOS 1.0" > /etc/issue.net
echo "BorealOS"     > /etc/debian_version

# Install wallpapers and assets
mkdir -p /usr/share/wallpapers/BorealOS
mkdir -p /usr/share/pixmaps
if [ -f /opt/borealOS/background_2.png ]; then
    cp /opt/borealOS/background_2.png /usr/share/wallpapers/BorealOS/default.png
fi
if [ -f /opt/borealOS/background_one.png ]; then
    cp /opt/borealOS/background_one.png /usr/share/wallpapers/BorealOS/waves.png
fi
if [ -f /opt/borealOS/logo.png ]; then
    cp /opt/borealOS/logo.png /usr/share/pixmaps/borealOS-logo.png
fi

apt-get update -qq 2>&1 || echo "Note: apt-get update had issues"

# Install in phases: core first, then extras
echo "Installing core packages..."
apt-get install -y --no-install-recommends \
    parted dosfstools e2fsprogs openrc sudo curl wget 2>&1 | tail -3 || true

echo "Installing kernel and bootloader..."
apt-get install -y --no-install-recommends \
    linux-image-amd64 grub-efi-amd64 efibootmgr 2>&1 | tail -3 || echo "Note: kernel/bootloader install had issues"

echo "Installing DE/network/utilities..."
apt-get install -y --no-install-recommends \
    network-manager neofetch $DE_PKGS $SHELL_PKG 2>&1 | tail -3 || true

echo "Package installation phase complete"

mkdir -p /etc/neofetch
cat > /etc/neofetch/config.conf <<NEOF
print_info() {
    info title
    info underline
    info "OS" distro
    info "Host" model
    info "Kernel" kernel
    info "Uptime" uptime
    info "Shell" shell
    info "DE/WM" de
    info "CPU" cpu
    info "Memory" memory
    prin ""
}
distro_shorthand="off"
os_arch="off"
kernel_shorthand="off"
NEOF

# Set root password with fallback for minimal systems
echo "root:$ROOT_PASS" | chpasswd 2>/dev/null || (echo "$ROOT_PASS"; echo "$ROOT_PASS") | passwd root 2>/dev/null || true
$USERS_SCRIPT
$NET_SCRIPT

# Setup boot loader
if [ ! -d /boot/efi ]; then
    mkdir -p /boot/efi
fi

if command -v grub-install >/dev/null 2>&1; then
    echo "Installing GRUB bootloader..."
    if [ -d /boot/efi ]; then
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BorealOS --no-nvram 2>&1 || {
            echo "Warning: EFI bootloader installation failed"
        }
        [ -f /etc/default/grub ] && sed -i 's/GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="BorealOS"/' /etc/default/grub 2>/dev/null || true
        if command -v update-grub >/dev/null 2>&1; then
            update-grub 2>&1 || echo "Note: update-grub had issues"
        fi
    fi
else
    echo "Note: GRUB bootloader not available in rootfs"
    echo "  System may not boot - you may need to install bootloader after first login"
fi

case "$DE_CHOICE" in
    "KDE Plasma")
        if command -v rc-update >/dev/null 2>&1; then
            rc-update add sddm default 2>/dev/null || true
        else
            mkdir -p /etc/rc2.d
            ln -sf /etc/init.d/sddm /etc/rc2.d/S99sddm 2>/dev/null || true
        fi
        mkdir -p /etc/sddm.conf.d
        cat > /etc/sddm.conf.d/borealos.conf <<SDDM
[General]
DisplayServer=x11
[Theme]
Background=/usr/share/wallpapers/BorealOS/default.png
SDDM
        ;;
    "XFCE")
        if command -v rc-update >/dev/null 2>&1; then
            rc-update add lightdm default 2>/dev/null || true
        else
            mkdir -p /etc/rc2.d
            ln -sf /etc/init.d/lightdm /etc/rc2.d/S99lightdm 2>/dev/null || true
        fi
        mkdir -p /etc/lightdm
        cat >> /etc/lightdm/lightdm-gtk-greeter.conf <<LDM
[greeter]
background=/usr/share/wallpapers/BorealOS/default.png
LDM
        mkdir -p /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
        cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<XFCE
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="/usr/share/wallpapers/BorealOS/default.png"/>
          <property name="image-style" type="int" value="5"/>
        </property>
      </property>
    </property>
  </property>
</channel>
XFCE
        ;;
    "Sway (Wayland)")
        mkdir -p /etc/sway
        cat > /etc/sway/config <<SWAY
set \$mod Mod4
font pango:monospace 10
output * bg /usr/share/wallpapers/BorealOS/default.png fill
input type:keyboard { xkb_layout us }
bindsym \$mod+Return exec foot
bindsym \$mod+d exec dmenu_run
bindsym \$mod+Shift+q kill
bindsym \$mod+Shift+e exec swaymsg exit
bar {
    statusbar_command while date +'%Y-%m-%d %H:%M'; do sleep 1; done
    colors {
        background #0d1b2a
        statusline #4dffd2
        focused_workspace #4dffd2 #0d1b2a #ffffff
    }
}
SWAY
        ;;
esac

if command -v rc-update >/dev/null 2>&1; then
    rc-update add NetworkManager default 2>/dev/null || true
else
    mkdir -p /etc/rc2.d
    ln -sf /etc/init.d/NetworkManager /etc/rc2.d/S99NetworkManager 2>/dev/null || true
fi
CHROOT

    echo -e "${CYN}Chroot configuration completed.${RST}"

cleanup() {
    echo -e "${CYN}Cleaning up...${RST}"
    # Unmount in reverse order
    umount /mnt/sys 2>/dev/null || true
    umount /mnt/proc 2>/dev/null || true
    umount /mnt/dev 2>/dev/null || true
    umount /mnt/run 2>/dev/null || true
    umount /mnt/boot/efi 2>/dev/null || true
    umount /mnt 2>/dev/null || true
}

finish() {
    banner
    echo -e "${GRN}${BLD}Installation complete.${RST}"
    echo
    echo "  Disk:    $DISK"
    echo "  DE/WM:   $DE_CHOICE"
    echo "  Shell:   $SHELL_CHOICE"
    echo "  Host:    $HOSTNAME"
    echo
    menu "What now?" "Reboot" "Drop to shell"
    case "$MENU_RESULT" in
        "Reboot") reboot ;;
        "Drop to shell")
            echo -e "${CYN}Type 'reboot' when done.${RST}"
            bash
            ;;
    esac
}

main() {
    check_root
    banner
    echo -e "${BLD}Welcome to the BorealOS Installer${RST}"
    echo
    confirm "Begin?" || die "Aborted."

    select_disk
    get_user_info
    get_extra_users
    select_de
    select_shell
    configure_network

    banner
    echo -e "${BLD}Summary:${RST}"
    echo "  Disk:         $DISK"
    echo "  Hostname:     $HOSTNAME"
    echo "  Timezone:     $TIMEZONE"
    echo "  DE/WM:        $DE_CHOICE"
    echo "  Shell:        $SHELL_CHOICE"
    echo "  Network:      $NET_TYPE"
    echo "  Extra users:  ${#EXTRA_USERS[@]}"
    echo
    confirm "Proceed?" || die "Aborted."

    echo -e "${CYN}Starting installation...${RST}"
    
    partition_disk
    echo -e "${CYN}Partitioning OK${RST}"; sleep 1
    
    mount_target
    echo -e "${CYN}Mounting OK${RST}"
    
    install_rootfs
    echo -e "${CYN}Rootfs extraction OK${RST}"
    
    chroot_install
    echo -e "${CYN}Chroot configuration OK${RST}"
    
    cleanup
    echo -e "${CYN}Cleanup OK${RST}"
    
    finish
}

trap cleanup EXIT
main
