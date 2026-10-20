#!/usr/bin/env bash
# Install or remove battery-limit. Run from a clone of the repository.
#   sudo ./install.sh              install and start
#   sudo ./install.sh --uninstall  remove (keeps /etc/battery-limit.conf and /var/lib/battery-limit)
# Environment: BINDIR (default /usr/local/bin), DESTDIR (staging root; skips systemd and udev reloads)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BINDIR="${BINDIR:-/usr/local/bin}"
D="${DESTDIR:-}"
UNIT="$D/etc/systemd/system/battery-limit.service"
RULE="$D/etc/udev/rules.d/99-battery-limit.rules"
CONF="$D/etc/battery-limit.conf"

if [ -z "$D" ] && [ "$(id -u)" != 0 ]; then
  echo "run with sudo" >&2
  exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
  if [ -z "$D" ]; then systemctl disable --now battery-limit.service 2>/dev/null || true; fi
  rm -f "$D$BINDIR/battery-limit" "$UNIT" "$RULE"
  if [ -z "$D" ]; then systemctl daemon-reload; udevadm control --reload; fi
  echo "Removed. Kept /etc/battery-limit.conf and /var/lib/battery-limit."
  exit 0
fi

install -Dm755 "$HERE/bin/battery-limit" "$D$BINDIR/battery-limit"
install -d "$D/var/lib/battery-limit"
[ -e "$CONF" ] || install -Dm644 "$HERE/config/battery-limit.conf" "$CONF"
install -d "$(dirname "$UNIT")"
sed "s|@BINDIR@|$BINDIR|g" "$HERE/systemd/battery-limit.service.in" > "$UNIT"
chmod 644 "$UNIT"
install -Dm644 "$HERE/udev/99-battery-limit.rules" "$RULE"

if [ -z "$D" ]; then
  systemctl daemon-reload
  udevadm control --reload
  systemctl enable --now battery-limit.service
  echo
  "$BINDIR/battery-limit" status
fi
