#!/usr/bin/env bash
# Live smoke test for the omatray widget. Run it inside the Omarchy session with
# the plugin installed. It opens two throwaway web apps (example.com and
# example.org), drives them through omarchy-shell IPC and asserts on what
# hyprctl reports. It backs up and restores the real dock file and closes the
# windows it opened, whatever happens.
#
# SMOKE_CLASS_PREFIX: window class prefix of the default browser's app windows
# (chrome for Chrome/Chromium, brave for Brave, ...).
set -euo pipefail

DOCK="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/omatray.json"
PREFIX="${SMOKE_CLASS_PREFIX:-chrome}"
HIDE_WS="special:omatray"
TIMEOUT="${SMOKE_TIMEOUT:-30}"

# id|url|class -- omarchy-launch-webapp produces <prefix>-<host>__<path>-<profile>
# for --app=<url>; with no path that is "<host>__" and the default profile.
APP_A=(smoke-a "https://example.com" "$PREFIX-example.com__-Default")
APP_B=(smoke-b "https://example.org" "$PREFIX-example.org__-Default")

WORK="$(mktemp -d)"
HAD_DOCK=0
FAILED=0

log()  { printf '==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; exit 1; }
pass() { printf '  ok: %s\n' "$*"; }

# ---- hyprland queries (everything goes through jq on `hyprctl clients -j`) ----
addr_of()   { hyprctl clients -j | jq -r --arg c "$1" \
                '[.[] | select((.class | ascii_downcase) == ($c | ascii_downcase))][0].address // empty'; }
ws_of()     { hyprctl clients -j | jq -r --arg a "$1" \
                '[.[] | select(.address == $a)][0].workspace.name // empty'; }
active_ws() { hyprctl activeworkspace -j | jq -r '.id'; }
focused()   { hyprctl activewindow -j | jq -r '.address // empty'; }
omatray()   { omarchy-shell omatray "$@"; }

# wait_until <description> <command...>: poll until the command succeeds.
wait_until() {
  local what="$1" i; shift
  for ((i = 0; i < TIMEOUT * 4; i++)); do
    if "$@"; then pass "$what"; return 0; fi
    sleep 0.25
  done
  fail "timed out waiting for: $what"
}

has_window()    { [[ -n "$(addr_of "$1")" ]]; }
no_window()     { [[ -z "$(addr_of "$1")" ]]; }
on_ws()         { [[ "$(ws_of "$(addr_of "$1")")" == "$2" ]]; }
on_active_ws()  { [[ "$(ws_of "$(addr_of "$1")")" == "$(hyprctl activeworkspace -j | jq -r '.name')" ]]; }
is_focused()    { local a; a="$(addr_of "$1")"; [[ -n "$a" && "$(focused)" == "$a" ]]; }

assert_ws_unchanged() {
  [[ "$(active_ws)" == "$1" ]] || fail "active workspace changed ($1 -> $(active_ws)) $2"
}

# ---- setup / teardown ----
write_dock() {
  mkdir -p "$(dirname "$DOCK")"
  # temp file + rename, the way the real helpers write it: exercises the
  # watcher surviving an inode change.
  jq -n --arg ia "${APP_A[0]}" --arg ua "${APP_A[1]}" --arg ca "${APP_A[2]}" \
        --arg ib "${APP_B[0]}" --arg ub "${APP_B[1]}" --arg cb "${APP_B[2]}" \
    '{apps: [
       {id: $ia, name: "Smoke A", matchClass: $ca, url: $ua},
       {id: $ib, name: "Smoke B", matchClass: $cb, url: $ub}]}' > "$DOCK.smoke-tmp"
  mv "$DOCK.smoke-tmp" "$DOCK"
}

close_by_class() {
  local a; a="$(addr_of "$1")"
  # hl.dsp.window.close falls back to the ACTIVE window when handed an empty
  # address, so never call it without one.
  [[ -n "$a" ]] || return 0
  hyprctl dispatch "hl.dsp.window.close({ window = \"address:$a\" })" >/dev/null || true
}

cleanup() {
  local rc=$?
  set +e
  log "Cleaning up"
  close_by_class "${APP_A[2]}"
  close_by_class "${APP_B[2]}"
  if ((HAD_DOCK)); then cp -f "$WORK/omatray.json.bak" "$DOCK"; else rm -f "$DOCK"; fi
  rm -f "$DOCK.smoke-tmp"
  rm -rf "$WORK"
  if ((rc == 0 && FAILED == 0)); then log "PASS"; else log "FAILED (exit $rc)"; fi
}
trap cleanup EXIT

preflight() {
  for c in hyprctl jq omarchy-shell omarchy-launch-webapp; do
    command -v "$c" >/dev/null || fail "missing command: $c"
  done
  has_window "${APP_A[2]}" && fail "a window of class ${APP_A[2]} is already open; close it first"
  has_window "${APP_B[2]}" && fail "a window of class ${APP_B[2]} is already open; close it first"
  if [[ -e "$DOCK" ]]; then cp -p "$DOCK" "$WORK/omatray.json.bak"; HAD_DOCK=1; fi
  return 0
}

# ---- steps ----
step_launch() {
  log "Launch both apps through the widget"
  write_dock
  sleep 3 # watcher + one poll tick: the widget must know the ids before IPC
  omatray toggle "${APP_A[0]}"
  wait_until "A window exists" has_window "${APP_A[2]}"
  omatray toggle "${APP_B[0]}"
  wait_until "B window exists" has_window "${APP_B[2]}"
  sleep 2 # let the widget's poll see both windows
}

step_hide() {
  log "Hide: both go to $HIDE_WS"
  local ws; ws="$(active_ws)"
  omatray hide "${APP_A[0]}"
  omatray hide "${APP_B[0]}"
  wait_until "A on $HIDE_WS" on_ws "${APP_A[2]}" "$HIDE_WS"
  wait_until "B on $HIDE_WS" on_ws "${APP_B[2]}" "$HIDE_WS"
  assert_ws_unchanged "$ws" "after hide"
  sleep 1
}

step_show() {
  log "Show A: only A comes back"
  local ws; ws="$(active_ws)"
  omatray show "${APP_A[0]}"
  wait_until "A on the active workspace" on_active_ws "${APP_A[2]}"
  wait_until "A focused" is_focused "${APP_A[2]}"
  on_ws "${APP_B[2]}" "$HIDE_WS" || fail "B left $HIDE_WS"
  pass "B still on $HIDE_WS"
  assert_ws_unchanged "$ws" "after show"
  pass "active workspace unchanged"
  sleep 1
}

step_toggle_hides_focused() {
  log "Toggle on the focused app minimizes it"
  omatray toggle "${APP_A[0]}"
  wait_until "A on $HIDE_WS" on_ws "${APP_A[2]}" "$HIDE_WS"
  omatray show "${APP_A[0]}"
  wait_until "A back on the active workspace" on_active_ws "${APP_A[2]}"
  sleep 1
}

step_quit() {
  log "Quit A: window gone, entry stays docked"
  omatray quit "${APP_A[0]}"
  wait_until "A window gone" no_window "${APP_A[2]}"
  jq -e --arg id "${APP_A[0]}" '.apps | map(.id) | index($id) != null' "$DOCK" >/dev/null \
    || fail "A was removed from the dock file"
  pass "A still in the dock file"
  has_window "${APP_B[2]}" || fail "quit A also closed B"
  pass "B untouched"
}

preflight
step_launch
step_hide
step_show
step_toggle_hides_focused
step_quit
