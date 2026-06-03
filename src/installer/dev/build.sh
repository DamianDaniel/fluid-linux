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

ISO=$(ls live-image-amd64.hybrid.iso 2>/dev/null || ls *.iso 2>/dev/null | head -1)
if [ -z "$ISO" ]; then
    echo "No ISO found"
    exit 1
fi

mkdir -p /mnt/hostshare
mount -t vboxsf hostshare /mnt/hostshare || echo "WARNING: VBoxSF mount failed, copy manually: $ISO"
cp "$ISO" /mnt/hostshare/borealoOS.iso && echo "ISO copied to hostshare"
