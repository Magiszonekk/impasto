#!/bin/sh
# Tymczasowe sudo bez hasła dla użytkownika, który wywołał sudo.
# Uruchom: sudo sh ~/sw.sh [minuty, domyślnie 60]
# Reguła leży w /run (tmpfs), więc znika też przy restarcie.
# Wymaga /etc/sudoers.d/98-sudo-window-include z "@includedir /run/sudo-window".
set -e
U=${SUDO_USER:?uruchom przez sudo}
MIN=${1:-60}
D=/run/sudo-window
F=$D/$U
T=$(mktemp)
printf 'Defaults:%s verifypw=any\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$U" "$U" > "$T"
visudo -cf "$T"
install -d -m 750 "$D"
install -m 440 -o root -g root "$T" "$F"
rm -f "$T"
systemctl stop sudo-window-off.timer 2>/dev/null || true
systemd-run --on-active="${MIN}min" --unit=sudo-window-off rm -f "$F"
echo "OK: sudo bez hasła do $(date -d "+${MIN} min" +%H:%M)"
