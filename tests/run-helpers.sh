#!/usr/bin/env bash
# Runs the keybind-helper tests against stub hyprctl/omarchy-shell/notify-send.
# Touches nothing outside a temp dir. No dependencies beyond python3.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
exec python3 -m unittest -v test_helpers
