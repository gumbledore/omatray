# omatray

Dock Chromium web apps into the Omarchy bar. Each app in your dock file gets
one icon with an unread badge. Minimizing parks the window on a hidden special
workspace (`special:omatray`), so the app stays signed in and warm; clicking the
icon brings it back.

![the widget and its menu](preview.png)

## Install

```sh
./install.sh
```

It runs the offline helper tests, copies the plugin and the helpers
(`omatray-dock`, `omatray-close`, `omatray-undock`, `omatray_dock.py`) to
`~/.local/bin`, validates the manifest, restarts the shell and puts the widget
in the bar. It is safe to run again. It does not touch your Hyprland files:
append `hypr/bindings.snippet.lua` to `~/.config/hypr/bindings.lua`, then

```sh
hyprctl reload && hyprctl configerrors
```

## Keys

| Key | Docked app | Anything else |
| --- | --- | --- |
| `SUPER+W` | Minimize to the tray | Close |
| `SUPER+ALT+W` | Really close (stays docked, icon dims) | Close |
| `SUPER+M` | Minimize to the tray | Chromium web app: dock it and minimize; otherwise a notification |
| `SUPER+ALT+M` | Undock; the window stays open | Notification |

Per-app key, using the entry's `id`:

```lua
o.bind("SUPER + SHIFT + O", "Outlook", "omarchy-shell -q omatray toggle outlook-work")
```

## Mouse

Left click behaves like a Dock tile:

- hidden: bring it to the current workspace and focus it
- focused: minimize it
- visible on another workspace: move it to the current one
- not running: launch it

Right click opens a menu: Show/Hide (`H`), Quit (`Q`), Remove from dock (`U`).

## IPC

```sh
omarchy-shell omatray toggle|show|hide|quit|menu|undock <id>
omarchy-shell omatray refresh
```

An unknown id is a logged no-op.

## Dock file

`${XDG_CONFIG_HOME:-~/.config}/omarchy/omatray.json`, watched live. `SUPER+M`
and the menu edit it for you; you can also write it by hand.

```json
{
  "apps": [
    {
      "id": "outlook-work",
      "name": "Outlook (Work)",
      "matchClass": "chrome-outlook.office.com__mail_-Work",
      "url": "https://outlook.office.com/mail/",
      "profile": "Work",
      "unreadPattern": "Inbox - (\\d+)"
    }
  ]
}
```

| Field | Required | Rule |
| --- | --- | --- |
| `id` | yes | `^[a-z0-9][a-z0-9-]{0,63}$` |
| `name` | yes | 1-64 characters |
| `matchClass` | yes | Window class, exact match, case-insensitive |
| `desktopId` | one of these two | Desktop file basename without `.desktop`; launched with `gtk-launch` |
| `url` | one of these two | `http`/`https`; launched with `omarchy-launch-webapp` |
| `profile` | no | Chromium profile directory, `^[A-Za-z0-9 _-]{1,64}$` |
| `icon` | no | Absolute path, icon-theme name, or a glyph |
| `unreadPattern` | no | JS regex string with one capture group, at most 128 characters |

Invalid entries are skipped with a warning; a malformed file gives an empty bar.
Chromium class names look like `chrome-<host>_<path with / as _>-<Profile>`.

## Unread badges

The count is the first `(N)` in the window title. `unreadPattern` replaces that
for one app. Outlook on the web puts no unread count in its title by default, so
expect no badge there without a custom pattern or an OWA setting that adds one.

To test the badge without a real notification:

```sh
omarchy bar set io.github.gumbledore.omatray debugUnread 3
```

## Conflicts and caveats

- `dougfour.desktop-undo` and `jam.grace-window` both take over `SUPER+W`. Do
  not run them alongside omatray.
- The Hyprland 4-finger-down touchpad gesture uses the built-in close, not
  `omatray-close`, so it really closes docked apps.
- Chromium-family browsers only. Popouts of a web app share the app's class.

## Testing

```sh
tests/run-helpers.sh   # offline: helpers against stub hyprctl/omarchy-shell
tests/smoke.sh         # live: opens example.com and example.org, needs the plugin installed
```

The smoke test backs up and restores your dock file and closes the windows it
opened.

## Credits

Forked from [haripako/plugin-microsoft-teams-omarchy](https://github.com/haripako/plugin-microsoft-teams-omarchy)
(MIT). Licensed MIT; see `LICENSE`.
