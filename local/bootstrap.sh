#!/usr/bin/env bash
# Faza 1: system. Uruchom z TTY na świeżym Archu (archinstall: btrfs + Limine
# w trybie ESP=/boot), jako zwykły użytkownik z sudo:
#   git clone <fork> ~/impasto && ~/impasto/local/bootstrap.sh
# Potem uruchom Hyprland i odpal local/finish.sh.
#
# Odtwarza: snapper + snap-pac, limine-snapper-sync, btrfs-overlayfs,
# /etc/default/limine (z wykrywaniem Windowsa/Ubuntu), multilib, sterownik
# NVIDIA z wczesnym KMS, /mnt/win i /mnt/ubuntu, przypięty mirrorlist
# (Arch Linux Archive), okno sudo.
# Skrypt jest idempotentny: kroki, które już są zrobione, pomija.
# PIN_DATE=RRRR/MM/DD ./bootstrap.sh  -> inna data niż "wczoraj".
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PIN_DATE=${PIN_DATE:-$(date -d yesterday +%Y/%m/%d)}
ARCHIVE=https://archive.archlinux.org/repos
USER_NAME=$(id -un)
# Partycje innych systemów do podmontowania (pusta wartość = pomiń).
WIN_UUID=${WIN_UUID-7CC22557C2251744}
UBUNTU_UUID=${UBUNTU_UUID-94acddf2-85da-4eba-9441-bbfd66d23463}
# Karta NVIDIA (vendor 0x10de, klasa 0x03xxxx = kontroler grafiki)?
NVIDIA=no
for d in /sys/bus/pci/devices/*; do
    [[ $(<"$d/vendor") == 0x10de && $(<"$d/class") == 0x03* ]] && NVIDIA=yes && break
done

b=$'\e[1m'; y=$'\e[33m'; r=$'\e[31m'; o=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$b" "$*" "$o"; }
warn() { printf '%s%s%s\n' "$y" "$*" "$o"; }
die()  { printf '%sBŁĄD:%s %s\n' "$r" "$o" "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "uruchom jako zwykły użytkownik (sudo woła sam skrypt)"
[[ $(findmnt -no FSTYPE /) == btrfs ]] || die "root nie jest na btrfs, snapshoty nie zadziałają"
command -v limine >/dev/null || die "brak limine. Ten skrypt zakłada bootloader Limine z archinstall"
mountpoint -q /boot || die "/boot nie jest osobnym montowaniem (ESP). Oczekiwano ESP=/boot"
sudo -v

step "multilib"
if ! grep -qE '^\[multilib\]' /etc/pacman.conf; then
    sudo cp /etc/pacman.conf /etc/pacman.conf.bak
    sudo sed -i -E '/^#\[multilib\]$/,/^#Include/ s/^#//' /etc/pacman.conf
fi
grep -qE '^\[multilib\]' /etc/pacman.conf || die "nie udało się włączyć multilib w /etc/pacman.conf"

step "Przypięcie repozytoriów do $PIN_DATE"
code=$(curl -s -o /dev/null -w '%{http_code}' "$ARCHIVE/$PIN_DATE/core/os/x86_64/core.db" || true)
[[ $code == 200 ]] || die "snapshot $PIN_DATE nie istnieje w archiwum (HTTP $code); podaj PIN_DATE"
[[ -e /etc/pacman.d/mirrorlist.rolling ]] || sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.rolling
echo "Server = $ARCHIVE/$PIN_DATE/\$repo/os/\$arch" | sudo tee /etc/pacman.d/mirrorlist >/dev/null
sudo systemctl disable --now reflector.timer 2>/dev/null || true
sudo pacman -Sy --noconfirm
hv=$(pacman -Si hyprland 2>/dev/null | awk '/^Version/{print $3}')
echo "hyprland w tym snapshocie: ${hv:-brak}"
case ${hv:-0} in 0.5[6-9]*|0.[6-9]*|[1-9]*) ;; *) warn "impasto wymaga hyprland >= 0.56; wybierz późniejszą PIN_DATE" ;; esac

step "Pakiety bazowe"
sudo pacman -S --needed --noconfirm git base-devel btrfs-progs snapper snap-pac \
    efibootmgr zram-generator inotify-tools \
    speedtest-cli tmux openssh nodejs npm ttf-dejavu
if [[ $NVIDIA == yes ]]; then
    step "Sterownik NVIDIA (open kernel modules)"
    sudo pacman -S --needed --noconfirm nvidia-open nvidia-utils lib32-nvidia-utils libva-nvidia-driver
fi

step "yay i narzędzia Limine z AUR"
if ! command -v yay >/dev/null; then
    tmp=$(mktemp -d)
    git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
    (cd "$tmp/yay-bin" && makepkg -si --noconfirm)
    rm -rf "$tmp"
fi
yay -S --needed --noconfirm limine-mkinitcpio-hook limine-snapper-sync

step "Snapper"
if ! sudo test -e /etc/snapper/configs/root; then
    if mountpoint -q /.snapshots; then sudo umount /.snapshots; fi
    sudo rmdir /.snapshots 2>/dev/null || true
    [[ ! -e /.snapshots ]] || die "/.snapshots nie jest pusty, sprawdź ręcznie"
    sudo snapper -c root create-config /
    sudo btrfs subvolume delete /.snapshots
    sudo mkdir /.snapshots
    if ! grep -qE '[[:space:]]/\.snapshots[[:space:]]' /etc/fstab; then
        # osobny subwolumen top-level @snapshots, żeby rollback @ go nie zabierał
        src=$(findmnt -no SOURCE / | sed 's/\[.*//')
        uuid=$(sudo blkid -s UUID -o value "$src")
        top=$(mktemp -d)
        sudo mount -o subvolid=5 "$src" "$top"
        sudo btrfs subvolume list "$top" | grep -q ' path @snapshots$' \
            || sudo btrfs subvolume create "$top/@snapshots"
        sudo umount "$top"; rmdir "$top"
        sudo cp /etc/fstab /etc/fstab.bak
        printf 'UUID=%s\t/.snapshots\tbtrfs\trw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@snapshots\t0 0\n' \
            "$uuid" | sudo tee -a /etc/fstab >/dev/null
    fi
    sudo systemctl daemon-reload
    sudo mount -a
    mountpoint -q /.snapshots || die "/.snapshots się nie zamontował"
    sudo chmod 750 /.snapshots
fi
sudo snapper -c root set-config TIMELINE_CREATE=no NUMBER_CLEANUP=yes \
    NUMBER_LIMIT=10 NUMBER_LIMIT_IMPORTANT=5 SYNC_ACL=yes "ALLOW_USERS=$USER_NAME"
sudo systemctl enable --now snapper-cleanup.timer

step "mkinitcpio: btrfs-overlayfs, bez fallbacku (ESP ma mało miejsca)"
if ! grep -qE '^HOOKS=.*btrfs-overlayfs' /etc/mkinitcpio.conf; then
    sudo cp /etc/mkinitcpio.conf /root/mkinitcpio.conf.bak
    if grep -qE '^HOOKS=.*[( ]fsck' /etc/mkinitcpio.conf; then
        sudo sed -i -E '/^HOOKS=/ s/ fsck/ btrfs-overlayfs fsck/' /etc/mkinitcpio.conf
    else
        sudo sed -i -E '/^HOOKS=/ s/\)$/ btrfs-overlayfs)/' /etc/mkinitcpio.conf
    fi
fi
grep -E '^HOOKS=' /etc/mkinitcpio.conf
sudo sed -i -E "s/^PRESETS=.*/PRESETS=('default')/" /etc/mkinitcpio.d/linux.preset
sudo rm -f /boot/initramfs-linux-fallback.img
if [[ $NVIDIA == yes ]]; then
    # wczesny KMS: splash i Hyprland od pierwszej klatki na nvidia_drm;
    # hook kms wciągałby nouveau do initramfs
    sudo install -m 644 /dev/stdin /etc/mkinitcpio.conf.d/nvidia.conf \
        <<< 'MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)'
    sudo sed -i -E '/^HOOKS=/ s/ kms( |\))/\1/' /etc/mkinitcpio.conf
fi

step "/etc/default/limine"
src=$(findmnt -no SOURCE / | sed 's/\[.*//')
partuuid=$(lsblk -no PARTUUID "$src")
extra=""
[[ $NVIDIA == yes ]] && extra=" nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
[[ -n $partuuid ]] || die "brak PARTUUID dla $src"
[[ ! -e /etc/default/limine ]] || sudo cp -n /etc/default/limine /root/limine.default.bak
sudo tee /etc/default/limine >/dev/null <<EOF
ESP_PATH="/boot"
TARGET_OS_NAME="Arch Linux"
UEFI_BOOT_ORDER=first
FIND_BOOTLOADERS=yes
ENABLE_UKI=no
MKINITCPIO_FALLBACK=no
KERNEL_CMDLINE[default]="root=PARTUUID=$partuuid rootflags=subvol=@ rootfstype=btrfs rw zswap.enabled=0$extra quiet splash"
EOF
sudo limine-update
sudo systemctl enable --now limine-snapper-sync.service
sudo rm -f /boot/vmlinuz-linux /boot/initramfs-linux.img

step "Partycje Windowsa i Ubuntu"
add_mount() { # uuid katalog typ opcje
    [[ -n $1 ]] || return 0
    if ! sudo blkid -U "$1" >/dev/null; then warn "brak partycji UUID=$1, pomijam $2"; return 0; fi
    grep -q "UUID=$1" /etc/fstab && return 0
    sudo mkdir -p "$2"
    [[ -e /etc/fstab.bak ]] || sudo cp /etc/fstab /etc/fstab.bak
    printf 'UUID=%s\t%s\t%s\t%s\t0 0\n' "$1" "$2" "$3" "$4" | sudo tee -a /etc/fstab >/dev/null
}
# Windows tylko do odczytu: zapis do NTFS bezpieczny dopiero po wyłączeniu
# Fast Startup w Windowsie (wtedy zmień ro na rw w /etc/fstab).
add_mount "$WIN_UUID" /mnt/win ntfs3 "ro,nofail,x-systemd.device-timeout=5s,uid=$(id -u),gid=$(id -g),iocharset=utf8"
add_mount "$UBUNTU_UUID" /mnt/ubuntu ext4 "rw,nofail,noatime,x-systemd.device-timeout=5s"
sudo systemctl daemon-reload
sudo mount -a || warn "mount -a zgłosił błąd, sprawdź /etc/fstab"

step "zram"
if [[ ! -e /etc/systemd/zram-generator.conf ]]; then
    printf '[zram0]\nzram-size = 4096\ncompression-algorithm = zstd\n' \
        | sudo tee /etc/systemd/zram-generator.conf >/dev/null
fi

step "Okno sudo bez hasła i skrypty użytkownika"
mkdir -p ~/.local/bin
install -m 755 "$HERE"/bin/sudo-window "$HERE"/bin/sys-update "$HERE"/bin/speedtest-window ~/.local/bin/
install -m 755 "$HERE"/bin/sw.sh ~/sw.sh
install -m 755 "$HERE"/bin/sys-update-reminder "$HERE"/bin/tools-autoupdate ~/.local/bin/
mkdir -p ~/.config/systemd/user
install -m 644 "$HERE"/systemd/*.service "$HERE"/systemd/*.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable sys-update-reminder.timer tools-autoupdate.timer 2>/dev/null \
    || warn "timery: włącz po zalogowaniu do sesji: systemctl --user enable --now sys-update-reminder.timer tools-autoupdate.timer"
sudo install -m 440 /dev/stdin /etc/sudoers.d/98-sudo-window-include <<< '@includedir /run/sudo-window'
sudo visudo -c >/dev/null && echo "sudoers OK"

step "Snapshot bazowy"
sudo snapper -c root create -d "czysta instalacja (bootstrap)" --print-number

cat <<EOF

${b}Gotowe.${o} Dalej:
  1. sudo reboot, sprawdź w menu Limine wpis "Arch Linux", podmenu Snapshots
     oraz wykryte wpisy Windows i Ubuntu,
  2. sprawdź kolejność: efibootmgr (firmware potrafi ją przestawić),
  3. uruchom Hyprland (start-hyprland), w kitty: ~/impasto/local/finish.sh
EOF
