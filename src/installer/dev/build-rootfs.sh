#!/bin/bash
set -e

if [ "$(id -u)" != "0" ]; then
    echo "Run as root"
    exit 1
fi

apt-get install -y debootstrap

ROOTFS="./borealoOS-rootfs"
rm -rf "$ROOTFS"

debootstrap --variant=minbase trixie "$ROOTFS" http://deb.debian.org/debian

mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"
mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"

chroot "$ROOTFS" /bin/bash << 'INNEREOF'
python3 - << 'PYEOF'
status_file = "/var/lib/dpkg/status"
with open(status_file, "r") as f:
    content = f.read()
blocks = content.split("\n\n")
new_blocks = []
for block in blocks:
    lines = block.split("\n")
    new_lines = []
    pkg_name = ""
    for line in lines:
        if line.startswith("Package:"):
            pkg_name = line.split(": ", 1)[1].strip()
        if pkg_name in ("systemd-sysv", "systemd") and line.startswith("Essential: yes"):
            line = "Essential: no"
        new_lines.append(line)
    new_blocks.append("\n".join(new_lines))
with open(status_file, "w") as f:
    f.write("\n\n".join(new_blocks))
PYEOF

apt-get install -y --no-install-recommends \
    -o APT::Force-LoopBreak=1 \
    -o Dpkg::Options::="--force-depends" \
    -o Dpkg::Options::="--force-remove-essential" \
    openrc sysvinit-core
dpkg --force-all --purge systemd-sysv systemd || true
apt-get -f install -y || true
apt-get clean

cat > /etc/os-release << OSEOF
PRETTY_NAME="BorealOS"
NAME="BorealOS"
ID=borealoOS
ID_LIKE=debian
OSEOF

cat > /etc/hostname << HEOF
borealoOS
HEOF
INNEREOF

umount "$ROOTFS/dev/pts"
umount "$ROOTFS/dev"
umount "$ROOTFS/sys"
umount "$ROOTFS/proc"

tar -czf borealoOS-rootfs.tar.gz -C "$ROOTFS" .
rm -rf "$ROOTFS"

mkdir -p /mnt/hostshare
mount -t vboxsf hostshare /mnt/hostshare || echo "WARNING: VBoxSF mount failed, copy manually"
cp borealoOS-rootfs.tar.gz /mnt/hostshare/ && echo "Rootfs copied to hostshare"
