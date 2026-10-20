-- Append to ~/.config/hypr/bindings.lua

-- Show/hide one docked app, like Cmd+Tab to it and Cmd+H away from it. The id
-- is the entry's "id" in ~/.config/omarchy/omatray.json. Copy the line for each
-- app you want a key for.
-- o.bind("SUPER + SHIFT + O", "Outlook", "omarchy-shell -q omatray toggle outlook-work")

-- SUPER+M docks the focused Chromium web app (adds it to the bar and minimizes
-- it to the tray), or just minimizes it if it is already docked. On any other
-- window it only shows a notification. M is not bound by stock Omarchy.
o.bind("SUPER + M", "Dock/minimize app", "omatray-dock")
-- SUPER+ALT+M removes the focused docked app from the dock (the window stays
-- open where it is, and SUPER+W closes it normally afterwards). On any other
-- window it only shows a notification.
o.bind("SUPER + ALT + M", "Undock app", "omatray-undock")

-- SUPER+W leaves a docked app running in the background instead of closing it:
-- the window is parked and the bar icon stays live. Every other window closes
-- as usual. SUPER+ALT+W closes the focused window for real; a docked app stays
-- docked and its icon dims. (The bar icon's right-click menu can also quit.)
--
-- The unbind is required, not optional. SUPER+W already carries Omarchy's
-- "Close window" binding, and binding a key twice does not replace the old
-- binding -- it STACKS. Without this line Hyprland runs both, so the app would
-- be hidden and then closed.
--
-- Requires bin/omatray-close, omatray-dock, omatray-undock and omatray_dock.py together
-- on your PATH; install.sh puts them in ~/.local/bin. They read the dock file
-- directly, so SUPER+W keeps working even when the shell is down.
hl.unbind("SUPER + W")
o.bind("SUPER + W", "Close window", "omatray-close")
o.bind("SUPER + ALT + W", "Force close window", "omatray-close --force")
