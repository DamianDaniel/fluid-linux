#!/bin/bash
set -e

WORK="$(pwd)/iso-work"
OUTPUT="borealOS.iso"
ROOTFS_TAR="./borealOS-rootfs.tar.gz"
INSTALLER_SH="./installer.sh"
WALLPAPER_DEFAULT="./background_2.png"
WALLPAPER_ALT="./background_one.png"
LOGO="./logo.png"

die() { echo "ERROR: $1" >&2; exit 1; }

for f in "$ROOTFS_TAR" "$INSTALLER_SH" "$WALLPAPER_DEFAULT" "$WALLPAPER_ALT" "$LOGO"; do
    [ -f "$f" ] || die "Missing $f"
done
[ "$EUID" -eq 0 ] || die "Run as root."

command -v xorriso       >/dev/null || apt-get install -y xorriso
command -v grub-mkrescue >/dev/null || apt-get install -y grub-efi-amd64-bin grub-pc-bin mtools
command -v mksquashfs    >/dev/null || apt-get install -y squashfs-tools

echo "==> Setting up work directory..."
rm -rf "$WORK"
mkdir -p "$WORK"/{iso/{boot/grub,live},squashfs-root}

echo "==> Extracting rootfs..."
tar -xzf "$ROOTFS_TAR" -C "$WORK/squashfs-root"

echo "==> Injecting installer and assets..."
mkdir -p "$WORK/squashfs-root/run/borealOS"
cp "$ROOTFS_TAR"        "$WORK/squashfs-root/run/borealOS/rootfs.tar.gz"
cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/run/borealOS/background_2.png"
cp "$WALLPAPER_ALT"     "$WORK/squashfs-root/run/borealOS/background_one.png"
cp "$LOGO"              "$WORK/squashfs-root/run/borealOS/logo.png"
cp "$INSTALLER_SH"      "$WORK/squashfs-root/usr/local/bin/borealOS-install"
chmod +x                "$WORK/squashfs-root/usr/local/bin/borealOS-install"

echo "==> Applying branding to live environment..."
cat > "$WORK/squashfs-root/etc/os-release" <<OS
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

cat > "$WORK/squashfs-root/etc/lsb-release" <<LSB
DISTRIB_ID=BorealOS
DISTRIB_RELEASE=1.0
DISTRIB_CODENAME=boreal
DISTRIB_DESCRIPTION="BorealOS 1.0"
LSB

echo "BorealOS"     > "$WORK/squashfs-root/etc/issue"
echo "BorealOS 1.0" > "$WORK/squashfs-root/etc/issue.net"
echo "BorealOS"     > "$WORK/squashfs-root/etc/debian_version"
echo "borealOS-live" > "$WORK/squashfs-root/etc/hostname"

mkdir -p "$WORK/squashfs-root/usr/share/wallpapers/BorealOS"
cp "$WALLPAPER_DEFAULT" "$WORK/squashfs-root/usr/share/wallpapers/BorealOS/default.png"
cp "$WALLPAPER_ALT"     "$WORK/squashfs-root/usr/share/wallpapers/BorealOS/waves.png"
mkdir -p "$WORK/squashfs-root/usr/share/pixmaps"
cp "$LOGO" "$WORK/squashfs-root/usr/share/pixmaps/borealOS-logo.png"

mkdir -p "$WORK/squashfs-root/etc/neofetch"
cat > "$WORK/squashfs-root/etc/neofetch/config.conf" <<NEOF
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

cat > "$WORK/squashfs-root/etc/profile.d/live-welcome.sh" <<'WELCOME'
if [ "$(tty)" = "/dev/tty1" ] && [ "$(id -u)" = "0" ]; then
    clear
    cat <<'BANNER'

  ____                       _  ___  ____
 | __ )  ___  _ __ ___  __ _| |/ _ \/ ___|
 |  _ \ / _ \| '__/ _ \/ _` | | | | \___ \
 | |_) | (_) | | |  __/ (_| | | |_| |___) |
 |____/ \___/|_|  \___|\__,_|_|\___/|____/

  Welcome to BorealOS Live
  Run: borealOS-install   to install
  Run: exit               to get a shell

BANNER
    borealOS-install
fi
WELCOME

echo "==> Installing kernel, live-boot and live tools into rootfs..."
mount --bind /dev  "$WORK/squashfs-root/dev"
mount --bind /proc "$WORK/squashfs-root/proc"
mount --bind /sys  "$WORK/squashfs-root/sys"
cp /etc/resolv.conf "$WORK/squashfs-root/etc/resolv.conf"

chroot "$WORK/squashfs-root" /bin/bash <<CHROOT
set -e
apt-get update -qq
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    live-boot \
    live-boot-initramfs-tools \
    parted \
    dosfstools \
    e2fsprogs \
    passwd \
    network-manager \
    iproute2 \
    wpasupplicant \
    tzdata \
    locales \
    sudo \
    bash
echo 'root:borealOS' | chpasswd
CHROOT

umount "$WORK/squashfs-root/sys" "$WORK/squashfs-root/proc" "$WORK/squashfs-root/dev"

tar -xOf "$ROOTFS_TAR" ./etc/inittab > "$WORK/squashfs-root/etc/inittab"
sed -i 's|^\(1:[0-9]*:respawn:.*getty\)|\1 --autologin root|' "$WORK/squashfs-root/etc/inittab"
if ! grep -q "autologin" "$WORK/squashfs-root/etc/inittab"; then
    sed -i '/^1:/d' "$WORK/squashfs-root/etc/inittab"
    echo "1:2345:respawn:/sbin/agetty --autologin root --noclear 38400 tty1" >> "$WORK/squashfs-root/etc/inittab"
fi

echo "==> Building SquashFS..."
mksquashfs "$WORK/squashfs-root" "$WORK/iso/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 19 -noappend -quiet

echo "==> Copying kernel and initrd..."
VMLINUZ=$(ls "$WORK/squashfs-root/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
INITRD=$(ls  "$WORK/squashfs-root/boot/initrd.img-"* 2>/dev/null | sort -V | tail -1)
[ -f "$VMLINUZ" ] || die "No kernel found in rootfs."
[ -f "$INITRD"  ] || die "No initrd found in rootfs."
cp "$VMLINUZ" "$WORK/iso/boot/vmlinuz"
cp "$INITRD"  "$WORK/iso/boot/initrd.img"

echo "==> Writing GRUB config..."
cat > "$WORK/iso/boot/grub/grub.cfg" <<'GRUB'
set timeout_style=menu
set timeout=10
set default=0
set menu_color_normal=cyan/black
set menu_color_highlight=black/cyan

menuentry "BorealOS Live Installer" {
    linux /boot/vmlinuz boot=live quiet splash
    initrd /boot/initrd.img
}

menuentry "BorealOS Live (safe mode)" {
    linux /boot/vmlinuz boot=live nomodeset
    initrd /boot/initrd.img
}
GRUB

echo "==> Building ISO..."
grub-mkrescue -o "$OUTPUT" "$WORK/iso" \
    --modules="normal iso9660 linux ext2 fat search search_label" \
    2>/dev/null

echo "==> Done: $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
