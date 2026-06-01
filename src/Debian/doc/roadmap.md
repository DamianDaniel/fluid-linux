# Debian ISO Roadmap

## Phase 1: Minimal ISO

Goal:

Boot a Debian-based BorealOS ISO in a virtual machine with `aurorad` as PID 1.

Requirements:

- bootable ISO
- aurorad starts as init
- TTY login or shell
- clean shutdown/reboot

## Phase 2: Base services

Target services:

- DBus
- networking
- logging
- cron or timer alternative
- SSH for debugging

## Phase 3: First graphical ISO

Recommended first desktop:

- XFCE

Reason:

XFCE is smaller and easier to debug than KDE Plasma for the first graphical
milestone.

## Phase 4: Desktop choices

Planned choices:

- XFCE
- KDE Plasma
- Sway

## Phase 5: Polish

- installer/live-session customization
- documentation
- man pages
- troubleshooting tools
- warnings before risky operations