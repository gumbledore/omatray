-- Append to ~/.config/hypr/bindings.lua

-- Hide/show the docked app without quitting it, the equivalent of Cmd+H on
-- macOS. Delegates to the plugin, which parks the window on a special workspace.
o.bind("SUPER + H", "Hide/show app", "omarchy-shell -q omatray toggle")

-- SUPER+W leaves the docked app running in the background instead of closing
-- it: the window is parked and the bar icon stays live. Every other window
-- closes as usual. To actually quit the app, use the bar icon's menu
-- (right-click).
--
-- The unbind is required, not optional. SUPER+W already carries Omarchy's
-- "Close window" binding, and binding a key twice does not replace the old
-- binding -- it STACKS. Without this line Hyprland runs both, so the app would
-- be hidden and then closed.
--
-- Requires bin/omatray-close on your PATH; install.sh puts it in ~/.local/bin.
-- It reads the widget's `matchClass` from shell.json.
hl.unbind("SUPER + W")
o.bind("SUPER + W", "Close window", "omatray-close")
