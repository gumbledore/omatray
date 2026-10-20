"""Shared code for the omatray keybind helpers (omatray-dock, omatray-close).

Stdlib only. Every subprocess is an argv list (never a shell), and the dock
file is only ever replaced atomically.
"""
import json
import os
import re
import shlex
import subprocess
import tempfile
import urllib.parse

HIDE_WORKSPACE = "special:omatray"

# Same rules as validateApp() in BarWidget.qml. Keep the two in step. Always
# use fullmatch(): in Python `$` also matches before a trailing newline.
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
CLASS_RE = re.compile(r"^[A-Za-z0-9._-]+$")
DESKTOP_RE = re.compile(r"^[A-Za-z0-9._ -]{1,128}$")
URL_RE = re.compile(r"^https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+$")
PROFILE_RE = re.compile(r"^[A-Za-z0-9 _-]{1,64}$")
ICON_PATH_RE = re.compile(r"^/[A-Za-z0-9._/ +-]+$")
ICON_NAME_RE = re.compile(r"^[A-Za-z0-9._+-]+$")
ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]+$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


def dock_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "omarchy", "omatray.json")


def js_len(text):
    """String length as the widget's JS counts it (UTF-16 code units)."""
    return len(text.encode("utf-16-le")) // 2


def validate_app(a):
    """Return an error string, or None when the entry is valid."""
    if not isinstance(a, dict):
        return "not an object"

    def s(key):
        v = a.get(key, "")
        return v if isinstance(v, str) else ""

    if not ID_RE.fullmatch(s("id")):
        return "bad id"
    if not 1 <= js_len(s("name")) <= 64 or CONTROL_RE.search(s("name")):
        return "bad name"
    if not CLASS_RE.fullmatch(s("matchClass")):
        return "bad matchClass"
    d, u, p = s("desktopId"), s("url"), s("profile")
    if d and not (DESKTOP_RE.fullmatch(d) and not d.startswith("-")):
        return "bad desktopId"
    if u and not URL_RE.fullmatch(u):
        return "bad url"
    if p and not PROFILE_RE.fullmatch(p):
        return "bad profile"
    if not d and not u:
        return "needs desktopId or url"
    return None


def load_dock():
    """Return (doc, apps), or None when the file is malformed.

    A missing file is a valid empty dock. A malformed one is not: callers must
    not write it, and must treat it as "nothing docked". `apps` holds only the
    valid entries (first of any duplicate id), as the widget sees them; `doc`
    keeps everything so a write does not drop entries the user hand-edited.
    """
    try:
        with open(dock_path(), encoding="utf-8") as f:
            doc = json.load(f)
    except FileNotFoundError:
        return {"apps": []}, []
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or not isinstance(doc.get("apps"), list):
        return None
    apps, seen = [], set()
    for a in doc["apps"]:
        if validate_app(a) is None and a["id"] not in seen:
            seen.add(a["id"])
            apps.append(a)
    return doc, apps


def find_by_class(apps, cls):
    """The widget matches the window class exactly, case-insensitively."""
    for a in apps:
        if a["matchClass"].lower() == cls.lower():
            return a
    return None


def write_dock(doc):
    """Atomically replace the dock file.

    Serialize first, then write a temp file in the same directory, fsync and
    rename over the original, so a crash or an unserializable value can never
    leave the real file truncated.
    """
    text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
    path = dock_path()
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".omatray.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def make_id(name, profile, taken):
    """Slug of the name, plus the profile unless it is Default; -2, -3... on clash."""
    base = slug(name)
    if profile and profile.lower() != "default":
        base += "-" + slug(profile)
    base = base.strip("-")[:60].strip("-") or "app"
    cand, n = base, 2
    while cand in taken:
        cand = "%s-%d" % (base, n)
        n += 1
    return cand


# ---- desktop entries ----

def window_class(url, profile):
    """Chromium's --app window class: chrome-<host>_<path, / -> _>-<Profile>.

    An empty path counts as "/", so https://mail.google.com gives
    chrome-mail.google.com__-Default and .../mail/ gives ...com__mail_-Work.
    """
    p = urllib.parse.urlsplit(url)
    return "chrome-%s_%s-%s" % (p.hostname or "", (p.path or "/").replace("/", "_"), profile or "Default")


def _desktop_dirs():
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return [os.path.join(base, "applications")]


def resolve_desktop(cls):
    """Find the omarchy-launch-webapp desktop file that produces window class `cls`.

    Returns {desktopId, name, icon, url, profile} or None. Exec is parsed as
    data only; nothing is executed.
    """
    for d in _desktop_dirs():
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for fn in names:
            if not fn.endswith(".desktop"):
                continue
            entry = _parse_desktop(os.path.join(d, fn))
            if not entry or not URL_RE.fullmatch(entry["url"]):
                continue
            if window_class(entry["url"], entry["profile"]).lower() == cls.lower():
                entry["desktopId"] = fn[: -len(".desktop")]
                return entry
    return None


def _parse_desktop(path):
    fields, in_main = {}, False
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("["):
                    in_main = line == "[Desktop Entry]"
                elif in_main and "=" in line:
                    k, v = line.split("=", 1)
                    fields.setdefault(k.strip(), v.strip())
        argv = shlex.split(fields.get("Exec", ""))
    except (OSError, ValueError):
        return None
    if len(argv) < 2 or os.path.basename(argv[0]) != "omarchy-launch-webapp":
        return None
    profile = "Default"
    for arg in argv[2:]:
        if arg.startswith("--profile-directory="):
            profile = arg.split("=", 1)[1] or "Default"
    return {"url": argv[1], "profile": profile, "name": fields.get("Name", ""), "icon": fields.get("Icon", "")}


def entry_from_class(cls, taken):
    """Build a dock entry for a window class, or None when it cannot be docked."""
    found = resolve_desktop(cls)
    if found:
        entry = {"name": found["name"], "matchClass": cls, "desktopId": found["desktopId"],
                 "url": found["url"], "profile": found["profile"], "icon": found["icon"]}
    else:
        m = re.match(r"^chrome-([^_]+)_(.*)-([^-]+)$", cls)
        if not m:
            return None
        host, path, profile = m.groups()
        # Only a bare host (path "/" -> "_") is unambiguous; anything else could
        # have been /a_b or /a/b. Without a desktop entry that leaves nothing to launch.
        if path != "_":
            return None
        entry = {"name": host, "matchClass": cls, "url": "https://%s/" % host, "profile": profile}
    name = entry["name"] or cls
    while js_len(name) > 64:
        name = name[:-1]
    entry["name"] = name
    if validate_app(dict(entry, id="x")) is not None:
        return None
    if not (ICON_PATH_RE.fullmatch(entry.get("icon", "")) or ICON_NAME_RE.fullmatch(entry.get("icon", ""))):
        entry.pop("icon", None)
    entry["id"] = make_id(entry["name"], entry.get("profile", ""), taken)
    # id first, matching how people write the file by hand.
    return {"id": entry.pop("id"), **entry}


# ---- talking to Hyprland, the shell and the desktop ----

def run(argv):
    """Run argv; return the exit code, or None if it could not be started."""
    try:
        return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=10).returncode
    except (OSError, subprocess.SubprocessError):
        return None


def notify(summary, body=""):
    # A missing notify-send must never fail the keybind.
    run(["notify-send", "-a", "omatray", summary, body])


def _hyprctl_json(*args):
    try:
        out = subprocess.run(["hyprctl", *args, "-j"], stdin=subprocess.DEVNULL,
                             capture_output=True, text=True, timeout=10).stdout
        return json.loads(out)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def active_window():
    """The focused window as a dict, or None when there is none.

    OMATRAY_WINDOW=<address> pins the window instead. The live smoke test uses
    it so that a focus change mid-run can never point a close at a real window.
    """
    pinned = os.environ.get("OMATRAY_WINDOW")
    if pinned is not None:
        clients = _hyprctl_json("clients")
        w = next((c for c in clients if isinstance(c, dict) and c.get("address") == pinned), None) \
            if isinstance(clients, list) else None
    else:
        w = _hyprctl_json("activewindow")
    if not isinstance(w, dict) or not isinstance(w.get("address"), str) or not ADDRESS_RE.fullmatch(w["address"]):
        return None
    return w


def lua_str(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def dispatch(expr):
    return run(["hyprctl", "dispatch", expr])


def close_window(address):
    # hl.dsp.window.close() falls back to the *active* window when handed
    # "address:", so an empty or odd address must never reach it.
    if not isinstance(address, str) or not ADDRESS_RE.fullmatch(address):
        return
    dispatch("hl.dsp.window.close({ window = %s })" % lua_str("address:" + address))


def move_to_hidden(address):
    if isinstance(address, str) and ADDRESS_RE.fullmatch(address):
        dispatch("hl.dsp.window.move({ window = %s, workspace = %s, follow = false })"
                 % (lua_str("address:" + address), lua_str(HIDE_WORKSPACE)))


def ipc(*args):
    return run(["omarchy-shell", "-q", "omatray", *args])


def park(address):
    """Minimize `address` to the tray. False, with nothing moved, when the shell is down.

    The helper moves the window itself: it has just read the address fresh, while
    the widget's copy can be a poll old (or missing for a just-relaunched app).
    """
    if ipc("refresh") != 0:
        return False
    move_to_hidden(address)
    ipc("refresh")
    return True


def is_popout(w):
    """True when `w` is not the first window of its class, the one the widget tracks.

    Chromium popouts (a message being composed, say) share the app's class.
    Parking one would hide a draft, so the helpers treat them as ordinary windows.
    If the client list can't be read, assume `w` is the main window.
    """
    clients = _hyprctl_json("clients")
    cls = (w.get("class") or "").lower()
    for c in clients if isinstance(clients, list) else []:
        if isinstance(c, dict) and str(c.get("class") or "").lower() == cls:
            return c.get("address") != w.get("address")
    return False
