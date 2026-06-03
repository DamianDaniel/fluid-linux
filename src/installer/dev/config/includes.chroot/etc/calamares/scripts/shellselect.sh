#!/bin/bash
CHROOT="$1"
if chroot "$CHROOT" dpkg -l fish 2>/dev/null | grep -q "^ii"; then
    chroot "$CHROOT" chsh -s /usr/bin/fish "$2" || true
else
    chroot "$CHROOT" chsh -s /bin/sh "$2" || true
fi
