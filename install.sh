#!/usr/bin/env bash
# Install this working tree into the live Omarchy shell, for development.
# A normal install is `omarchy plugin add`, which keeps a git checkout that
# `omarchy plugin update` can pull.
#
# Omarchy rejects symlinks inside a plugin folder, so the files are copied.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/io.github.gumbledore.omatray"

# Fail fast, before anything live is touched.
echo "==> Helper tests (offline)"
"$REPO/tests/run-helpers.sh" >/dev/null 2>&1 || {
  echo "Helper tests failed; run tests/run-helpers.sh to see why." >&2
  exit 1
}

if [ -d "$DEST/.git" ]; then
  echo "$DEST is managed by 'omarchy plugin'; update it with: omarchy plugin update io.github.gumbledore.omatray" >&2
  exit 1
fi

echo "==> Copying plugin to $DEST"
mkdir -p "$DEST/bin"
cp "$REPO/manifest.json" "$REPO/BarWidget.qml" "$DEST/"
for f in omatray-close omatray-dock omatray-undock; do
  install -m 0755 "$REPO/bin/$f" "$DEST/bin/$f"
done
install -m 0644 "$REPO/bin/omatray_dock.py" "$DEST/bin/omatray_dock.py"

echo "==> Validating"
omarchy plugin validate "$DEST"

if command -v /usr/lib/qt6/bin/qmllint >/dev/null; then
  SHIM="$(mktemp -d)"
  ln -sfn /usr/share/omarchy/shell "$SHIM/qs"
  echo "==> qmllint (warnings about 'bar' and 'Style.font' are expected; stock widgets have them too)"
  /usr/lib/qt6/bin/qmllint -I "$SHIM" -I /usr/lib/qt6/qml "$DEST/BarWidget.qml" \
    2>&1 | grep -oE "\[[a-z-]+\]$" | sort | uniq -c || true
  rm -rf "$SHIM"
fi

# rescanPlugins discovers a plugin but keeps the old QML instance alive, so a
# full shell restart is the only way to pick up code changes.
echo "==> Restarting the Omarchy shell"
omarchy restart shell
sleep 5

# Placement only. Deliberately no `omarchy bar set` here: it would overwrite
# settings the user may have chosen. `put` leaves a widget that is already on
# the bar where it is, so re-running is harmless.
echo "==> Bar placement"
omarchy bar put io.github.gumbledore.omatray --section right --index 0 || true

# Nothing here can minimize or close a window: `refresh` takes no app, and an
# unknown id is a logged no-op.
echo "==> IPC check"
check() {
  printf '    %-34s ' "$*"
  local out rc=0
  out="$(omarchy-shell omatray "$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then echo "OK"; else echo "FAILED (exit $rc) $out"; fi
  sleep 1
}
check refresh
check toggle __omatray_install_check__

cat <<'EOF'

Done. One thing this script deliberately does NOT do, because it appends to a
file you also edit by hand:

  - hypr/bindings.snippet.lua   -> append to ~/.config/hypr/bindings.lua
    (SUPER+W minimize/close, SUPER+ALT+W force close, SUPER+M dock/minimize,
     SUPER+ALT+M undock, via the helpers in the plugin's bin/)

After appending: hyprctl reload && hyprctl configerrors
EOF
