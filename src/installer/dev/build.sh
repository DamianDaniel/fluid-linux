#!/bin/bash
set -e

if [ "$(id -u)" != "0" ]; then
    echo "Run as root"
    exit 1
fi

apt-get install -y live-build calamares calamares-settings-debian

cd "$(dirname "$0")"
lb clean
bash auto/config
lb build

echo "Done. ISO: $(ls *.iso)"
