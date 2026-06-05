#!/bin/bash
set -e

if [ "$(id -u)" != "0" ]; then
    echo "Run as root"
    exit 1
fi

apt-get install -y live-build calamares calamares-settings-debian curl

date -s "$(curl -sI google.com | grep -i '^date:' | cut -d' ' -f2-)"

cd "$(dirname "$0")"
lb clean
bash auto/config
lb build

echo "Swapping systemd for openrc in rootfs..."
mount --bind /proc chroot/proc
mount --bind /sys chroot/sys
mount --bind /dev chroot/dev
mount --bind /dev/pts chroot/dev/pts

chroot chroot /bin/bash << 'INNEREOF'
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
apt-get autoremove -y || true
INNEREOF

umount chroot/dev/pts
umount chroot/dev
umount chroot/sys
umount chroot/proc

echo "Creating rootfs tarball..."
tar -czf borealoOS-rootfs.tar.gz chroot/

ISO=$(ls live-image-amd64.hybrid.iso 2>/dev/null || ls *.iso 2>/dev/null | head -1)
if [ -z "$ISO" ]; then
    echo "No ISO found"
    exit 1
fi

mkdir -p /mnt/hostshare
mount -t vboxsf hostshare /mnt/hostshare || echo "WARNING: VBoxSF mount failed"
cp "$ISO" /mnt/hostshare/borealoOS.iso && echo "ISO copied to hostshare"
cp borealoOS-rootfs.tar.gz /mnt/hostshare/borealoOS-rootfs.tar.gz && echo "Rootfs copied to hostshare"
