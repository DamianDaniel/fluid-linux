#!/bin/bash
CHROOT="$1"
chroot "$CHROOT" /bin/bash << 'INNEREOF'
apt-get install -y --no-install-recommends \
    -o APT::Force-LoopBreak=1 \
    -o Dpkg::Options::="--force-depends" \
    -o Dpkg::Options::="--force-remove-essential" \
    openrc sysvinit-core
apt-get remove --purge -y \
    -o APT::Force-LoopBreak=1 \
    -o Dpkg::Options::="--force-depends" \
    -o Dpkg::Options::="--force-remove-essential" \
    systemd-sysv systemd || true
apt-get -f install -y || true
apt-get autoremove -y || true
INNEREOF
