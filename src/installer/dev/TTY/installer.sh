#!/bin/bash
set -e

RED='\033[0;31m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

die() { echo -e "${RED}ERROR: $1${RST}" >&2; exit 1; }

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

get_user_info() {
    banner
    ask "Hostname" HOSTNAME "borealOS"
    ask "Root password" ROOT_PASS
    ask "New username" USERNAME
    ask "User password" USER_PASS
    ask "Timezone (e.g. Europe/Berlin)" TIMEZONE "UTC"
    ask "Locale (e.g. en_US.UTF-8)" LOCALE "en_US.UTF-8"
}

install_wallpapers() {
    mkdir -p /mnt/usr/share/wallpapers/BorealOS
    cp /run/borealOS/background_2.png  /mnt/usr/share/wallpapers/BorealOS/default.png
    cp /run/borealOS/background_one.png /mnt/usr/share/wallpapers/BorealOS/waves.png
    cp /run/borealOS/logo.png           /mnt/usr/share/pixmaps/borealOS-logo.png
}

chroot_install() {
    banner
    echo -e "${BLD}Configuring system in chroot...${RST}"

    for d in dev proc sys run; do mount --bind /$d /mnt/$d; done
    cp /etc/resolv.conf /mnt/etc/resolv.conf

    case "$DE_CHOICE" in
        "KDE Plasma") DE_PKGS="kde-plasma-desktop sddm" ;;
        "XFCE")       DE_PKGS="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter" ;;
        "Sway (Wayland)") DE_PKGS="sway swaybar swaybg swaylock waybar foot" ;;
        *)            DE_PKGS="" ;;
    esac

    case "$SHELL_CHOICE" in
        fish) SHELL_PKG="fish"; SHELL_BIN="/usr/bin/fish" ;;
        sh)   SHELL_PKG=""; SHELL_BIN="/bin/sh" ;;
        *)    SHELL_PKG=""; SHELL_BIN="/bin/bash" ;;
    esac

    chroot /mnt /bin/bash <<CHROOT
set -e

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
HOSTS

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime

sed -i "s/# *$LOCALE/$LOCALE/" /etc/locale.gen
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

rm -f /etc/lsb-release
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

mkdir -p /etc/profile.d
cat > /etc/profile.d/neofetch-override.sh <<NEO
export NEOFETCH_DISTRO="BorealOS 1.0"
NEO

echo "root:$ROOT_PASS" | chpasswd
useradd -m -G sudo,audio,video,netdev -s $SHELL_BIN $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd

cp /usr/share/wallpapers/BorealOS/default.png /usr/share/wallpapers/BorealOS/default.png

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
        mkdir -p /etc/plasma-workspace/env
        cat > /usr/share/plasma/look-and-feel/borealos/contents/defaults <<PLASMA
[Wallpaper]
Image=file:///usr/share/wallpapers/BorealOS/default.png
PLASMA
        kwriteconfig5 --file kdeglobals --group "KDE" --key "LookAndFeelPackage" "org.kde.breeze.desktop" 2>/dev/null || true
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
input type:keyboard {
    xkb_layout us
}
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
        mkdir -p /home/$USERNAME/.config/sway
        cp /etc/sway/config /home/$USERNAME/.config/sway/config
        chown -R $USERNAME:$USERNAME /home/$USERNAME/.config
        ;;
esac

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BorealOS
sed -i 's/GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="BorealOS"/' /etc/default/grub
update-grub

rc-update add NetworkManager default

dpkg-query -l 2>/dev/null | grep -i "debian\|raspbian" | awk '{print $2}' | xargs apt-get remove -y --purge 2>/dev/null || true
rm -f /usr/share/doc/*/copyright 2>/dev/null || true

CHROOT

    echo -e "${GRN}Chroot done.${RST}"
}

cleanup() {
    echo -e "${BLD}Unmounting...${RST}"
    umount -R /mnt 2>/dev/null || true
}

finish() {
    banner
    echo -e "${GRN}${BLD}Installation complete.${RST}"
    echo
    echo "  Disk:    $DISK"
    echo "  DE/WM:   $DE_CHOICE"
    echo "  Shell:   $SHELL_CHOICE"
    echo "  User:    $USERNAME"
    echo "  Host:    $HOSTNAME"
    echo
    confirm "Reboot now?" && reboot
}

main() {
    check_root
    banner
    echo -e "${BLD}Welcome to the BorealOS Installer${RST}"
    echo "This will install BorealOS onto your system."
    echo
    confirm "Begin installation?" || die "Aborted."

    select_disk
    get_user_info
    select_de
    select_shell

    banner
    echo -e "${BLD}Summary:${RST}"
    echo "  Disk:      $DISK"
    echo "  Hostname:  $HOSTNAME"
    echo "  User:      $USERNAME"
    echo "  Timezone:  $TIMEZONE"
    echo "  DE/WM:     $DE_CHOICE"
    echo "  Shell:     $SHELL_CHOICE"
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
