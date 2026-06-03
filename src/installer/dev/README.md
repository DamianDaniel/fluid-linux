# BorealOS Build System

## Requirements
- Debian trixie host (or VM)
- Root access
- ~20GB free disk space
- Internet connection

## Build
```bash
sudo bash build.sh
```

## What this produces
- Hybrid ISO bootable from USB/DVD
- Live environment: KDE Plasma, auto-login as user `boreal`
- Installer (Calamares) with DE selection: KDE Plasma, XFCE, Sway
- openrc replaces systemd by default on installed system

## Flash to USB
```bash
dd if=borealos-amd64.hybrid.iso of=/dev/sdX bs=4M status=progress
```

## Notes
- The openrc hook runs during chroot build — if it fails, check hook logs in `chroot/debootstrap/`
- Calamares DE selection uses netinstall module — requires internet during install
- To add packages to live ISO, add `.list.chroot` files in `config/package-lists/`
