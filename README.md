# omatray

Dock any Chromium web app into the Omarchy bar: minimize to tray, unread badge,
show/hide. Work in progress; this early version drives a single hardcoded web
app (`url` and `matchClass` settings) until the dock list lands.

![the widget and its menu](preview.png)

## What it does

- **Dock-style icon.** Click to show or focus the app; click again while it is
  focused to hide it.
- **Unread badge.** The count comes from a leading `(3)` in the window title.
- **Hide instead of quit.** Hiding parks the window on `special:omatray`, so the
  app stays signed in and warm. Showing moves it to the current workspace.
- **Right-click menu** with show/hide and Quit (`h` and `q` keys).

## Install

```sh
./install.sh
```

Then append `hypr/bindings.snippet.lua` to `~/.config/hypr/bindings.lua` and run
`hyprctl reload`. That makes `SUPER+H` toggle the app and `SUPER+W` hide it
instead of closing it.

## Control

```sh
omarchy-shell omatray toggle|show|hide|quit|refresh
```

## Credits

Forked from [haripako/plugin-microsoft-teams-omarchy](https://github.com/haripako/plugin-microsoft-teams-omarchy)
(MIT). Licensed MIT; see `LICENSE`.
