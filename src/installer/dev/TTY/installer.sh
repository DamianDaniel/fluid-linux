#!/bin/bash
set -e

RED='\033[0;31m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

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
        echo -ne "${CYN}${prompt}${RST}: "
        read -rs pass1; echo
        echo -ne "${CYN}Confirm ${prompt}${RST}: "
        read -rs pass2; echo
        if [ "$pass1" = "$pass2" ] && [ -n "$pass1" ]; then
            printf -v "$var" '%s' "$pass1"
            return
        fi
        echo -e "${RED}Passwords do not match or are empty.${RST}"
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
        echo -e "${RED}Invalid choice.${RST}"
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
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary ext4 513MiB 100%
    if [[ "$DISK" == *nvme* ]]; then
        EFI="${DISK}p1"; ROOT="${DISK}p2"
    else
        EFI="${DISK}1"; ROOT="${DISK}2"
    fi
    mkfs.fat -F32 -n EFI "$EFI"
    mkfs.ext4 -L borealOS "$ROOT"
    echo -e "${GRN}Done.${RST}"
}

mount_target() {
    mount "$ROOT" /mnt
    mkdir -p /mnt/boot/efi
    mount "$EFI" /mnt/boot/efi
}

install_rootfs() {
    banner
    echo -e "${BLD}Installing base system...${RST}"
    tar -xzf /run/borealOS/rootfs.tar.gz -C /mnt
    echo -e "${GRN}Done.${RST}"
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
    echo -e "${BLD}Available regions (type to filter or press enter to list all):${RST}"
    echo -ne "${CYN}Region filter${RST}: "
    read -r tz_filter
    echo
    mapfile -t tz_list < <(timedatectl list-timezones 2>/dev/null | grep -i "${tz_filter}" | head -40)
    if [ ${#tz_list[@]} -eq 0 ]; then
        echo -e "${RED}No timezones matched. Defaulting to UTC.${RST}"
        TIMEZONE="UTC"
        return
    fi
    for i in "${!tz_list[@]}"; do
        echo "  $((i+1))) ${tz_list[$i]}"
    done
    echo
    while true; do
        echo -ne "${CYN}Choice (or 0 to type manually)${RST}: "
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
    EXTRA_USERS=()
    echo -e "${BLD}User accounts${RST}"
    echo "Add non-root user accounts. Enter blank name when done."
    echo
    while true; do
        echo -ne "${CYN}Username (blank to stop)${RST}: "
        read -r uname
        [ -z "$uname" ] && break
        ask_pass "Password for $uname" upass
        EXTRA_USERS+=("$uname:$upass")
        echo -e "${GRN}Added $uname.${RST}"
    done
}

configure_network() {
    banner
    echo -e "${BLD}Network configuration${RST}"
    echo
    menu "Network type:" "DHCP (automatic)" "Static IP" "Skip (configure later)"
    NET_TYPE="$MENU_RESULT"

    if [ "$NET_TYPE" = "Static IP" ]; then
        ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | tr -d ':'
        echo
        ask "Network interface (e.g. eth0)" NET_IF "eth0"
        ask "IP address (e.g. 192.168.1.100/24)" NET_IP
        ask "Gateway (e.g. 192.168.1.1)" NET_GW
        ask "DNS server" NET_DNS "1.1.1.1"
    elif [ "$NET_TYPE" = "DHCP (automatic)" ]; then
        ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | tr -d ':'
        echo
        ask "Network interface (e.g. eth0)" NET_IF "eth0"
    fi
}

install_wallpapers() {
    mkdir -p /mnt/usr/share/wallpapers/BorealOS
    cp /run/borealOS/background_2.png   /mnt/usr/share/wallpapers/BorealOS/default.png
    cp /run/borealOS/background_one.png /mnt/usr/share/wallpapers/BorealOS/waves.png
    mkdir -p /mnt/usr/share/pixmaps
    cp /run/borealOS/logo.png           /mnt/usr/share/pixmaps/borealOS-logo.png
}

chroot_install() {
    banner
    echo -e "${BLD}Configuring system in chroot...${RST}"

    for d in dev proc sys run; do mount --bind /$d /mnt/$d; done
    cp /etc/resolv.conf /mnt/etc/resolv.conf

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
        uname="${entry%%:*}"
        upass="${entry##*:}"
        USERS_SCRIPT+="useradd -m -G sudo,audio,video,netdev -s $SHELL_BIN $uname"$'\n'
        USERS_SCRIPT+="echo '$uname:$upass' | chpasswd"$'\n'
    done

    NET_SCRIPT=""
    if [ "$NET_TYPE" = "DHCP (automatic)" ]; then
        NET_SCRIPT="cat > /etc/NetworkManager/system-connections/${NET_IF}.nmconnection <<NMC
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
        NET_SCRIPT="cat > /etc/NetworkManager/system-connections/${NET_IF}.nmconnection <<NMC
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

    chroot /mnt /bin/bash <<CHROOT
set -e

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
HOSTS

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime

sed -i "s/# *$LOCALE/$LOCALE/" /etc/locale.gen 2>/dev/null || echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

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

echo "BorealOS" > /etc/issue
echo "BorealOS 1.0" > /etc/issue.net
echo "BorealOS" > /etc/debian_version

apt-get update -qq
apt-get install -y --no-install-recommends \
    linux-image-amd64 grub-efi-amd64 efibootmgr \
    openrc \
    networkmanager \
    neofetch \
    parted dosfstools e2fsprogs \
    sudo curl wget \
    $DE_PKGS $SHELL_PKG

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

echo "root:$ROOT_PASS" | chpasswd
$USERS_SCRIPT

mkdir -p /etc/NetworkManager/system-connections
$NET_SCRIPT

case "$DE_CHOICE" in
    "KDE Plasma")
        rc-update add sddm default
        mkdir -p /etc/sddm.conf.d
        cat > /etc/sddm.conf.d/borealos.conf <<SDDM
[General]
DisplayServer=x11
[Theme]
Background=/usr/share/wallpapers/BorealOS/default.png
SDDM
        ;;
    "XFCE")
        rc-update add lightdm default
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

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BorealOS
sed -i 's/GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="BorealOS"/' /etc/default/grub
update-grub

rc-update add NetworkManager default
CHROOT

    echo -e "${GRN}Chroot done.${RST}"
}

cleanup() {
    umount -R /mnt 2>/dev/null || true
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
            echo -e "${CYN}Entering shell. Type 'reboot' when done.${RST}"
            bash
            ;;
    esac
}

main() {
    check_root
    banner
    echo -e "${BLD}Welcome to the BorealOS Installer${RST}"
    echo
    confirm "Begin installation?" || die "Aborted."

    select_disk
    get_user_info
    get_extra_users
    select_de
    select_shell
    configure_network

    banner
    echo -e "${BLD}Summary:${RST}"
    echo "  Disk:      $DISK"
    echo "  Hostname:  $HOSTNAME"
    echo "  Timezone:  $TIMEZONE"
    echo "  DE/WM:     $DE_CHOICE"
    echo "  Shell:     $SHELL_CHOICE"
    echo "  Network:   $NET_TYPE"
    echo "  Extra users: ${#EXTRA_USERS[@]}"
    echo
    confirm "Proceed?" || die "Aborted."

    partition_disk
    mount_target
    install_rootfs
    install_wallpapers
    chroot_install
    cleanup
    finish
}

trap cleanup EXIT
main
