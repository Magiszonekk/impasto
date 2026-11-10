#!/usr/bin/env bash
# Faza 2: z wnętrza działającej sesji Hyprland (impasto buduje pluginy pod
# działający kompozytor). Robi: ./setup install, narzędzia użytkownika
# (Claude Code, Hermes, herdr), domyślne aplikacje i układ paska.
# Idempotentny: ponowne uruchomienie jest bezpieczne.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$HERE")

b=$'\e[1m'; y=$'\e[33m'; o=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$b" "$*" "$o"; }
warn() { printf '%s%s%s\n' "$y" "$*" "$o"; }

[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || { echo "Uruchom to z sesji Hyprland (nie z TTY)." >&2; exit 1; }
export PATH="$HOME/.local/bin:$PATH"

step "Snapshot przed impasto"
sudo snapper -c root create -d "przed impasto (finish.sh)" --print-number

step "impasto: ./setup install"
(cd "$REPO" && ./setup install --noconfirm)

# Splash: ./setup splash edytuje generowany /boot/limine.conf, więc robimy to
# przez /etc/default/limine i blokujemy ten krok stampem.
step "Splash (Plymouth)"
mkdir -p ~/.local/state/impasto/applied
if [[ ! -e ~/.local/state/impasto/applied/splash ]]; then
    if command -v plymouth-set-default-theme >/dev/null && sudo plymouth-set-default-theme -l | grep -qx impasto; then
        sudo plymouth-set-default-theme impasto
        grep -q 'splash' /etc/default/limine || sudo sed -i -E '/^KERNEL_CMDLINE\[default\]=/ s/"$/ quiet splash"/' /etc/default/limine
        sudo limine-update
        : > ~/.local/state/impasto/applied/splash
    else
        warn "motyw plymouth 'impasto' niedostępny, pomijam splash"
    fi
fi

step "Claude Code"
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash

step "Hermes Agent"
command -v hermes >/dev/null || curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive

step "herdr"
command -v herdr >/dev/null || curl -fsSL https://releases.herdr.dev/app/install.sh | sh

step "Integracje herdr (Claude Code, Hermes)"
for t in claude hermes; do
    herdr integration install "$t" || warn "integracja herdr/$t nie zadziałała"
done

step "Domyślne aplikacje i układ paska"
[[ -e ~/.config/mimeapps.list ]] && cp -n ~/.config/mimeapps.list ~/.config/mimeapps.list.pre-local
cp "$HERE/config/mimeapps.list" ~/.config/mimeapps.list
mkdir -p ~/.local/state/quickshell
[[ -e ~/.local/state/quickshell/settings.json ]] && cp -n ~/.local/state/quickshell/settings.json ~/.local/state/quickshell/settings.json.pre-local
cp "$HERE/config/quickshell-settings.json" ~/.local/state/quickshell/settings.json

cat <<EOF

${b}Gotowe.${o} Ręcznie zostaje:
  - logowanie: claude (konto), hermes setup (klucze API/provider), Spotify (uruchom raz, potem ./setup spotify)
  - Brave/Zed/FileZilla są w packages/ (local), więc ./setup install je już postawił
  - wyloguj się i zaloguj, żeby pasek wczytał układ; sys-update sprawdzisz poleceniem: sys-update
EOF
