"""Fake-PATH tests for bin/omatray-dock, omatray-close and omatray-undock.

To add a case: write a method on HelperTests that calls self.dock(),
self.close() or self.undock() (optionally with active=window(...), shell_down=True, dock=<text>),
then assert on self.calls() (the stub log) and self.read_dock(). Every case also
runs the global "no close without a 0x address" check in tearDown.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "..", "bin")
sys.path.insert(0, BIN)
import omatray_dock as d  # noqa: E402

DESKTOP = """[Desktop Entry]
Name={name}
Exec=omarchy-launch-webapp {url}{flag}
Icon={icon}
"""
FILES = {
    "Outlook.desktop": ("Outlook", "https://outlook.office.com/mail/", " --profile-directory=Work", "outlook"),
    "Outlook Personal.desktop": ("Outlook Personal", "https://outlook.office.com/mail/", " --profile-directory=Default", "outlook"),
    "Gmail.desktop": ("Gmail", "https://mail.google.com", " --profile-directory=Default", "gmail"),
    "NoFlag.desktop": ("Notes", "https://notes.example.com/app", "", "notes"),
}
OUTLOOK_WORK = "chrome-outlook.office.com__mail_-Work"
OUTLOOK_DEFAULT = "chrome-outlook.office.com__mail_-Default"
GMAIL = "chrome-mail.google.com__-Default"
ADDR = "0xabc123"


def window(cls, addr=ADDR):
    return json.dumps({"address": addr, "class": cls})


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        stubs = os.path.join(self.tmp, "stubs")
        os.mkdir(stubs)
        for n in ("hyprctl", "omarchy-shell", "notify-send"):
            os.symlink(os.path.join(HERE, "helpers", "stub"), os.path.join(stubs, n))
        self.log = os.path.join(self.tmp, "calls.log")
        self.cfg = os.path.join(self.tmp, "config")
        apps = os.path.join(self.tmp, "data", "applications")
        os.makedirs(apps)
        for fn, (name, url, flag, icon) in FILES.items():
            with open(os.path.join(apps, fn), "w") as f:
                f.write(DESKTOP.format(name=name, url=url, flag=flag, icon=icon))
        with open(os.path.join(apps, "Terminal.desktop"), "w") as f:
            f.write("[Desktop Entry]\nName=Term\nExec=alacritty\n")
        self.dockfile = os.path.join(self.cfg, "omarchy", "omatray.json")
        self.env = dict(os.environ, PATH=stubs + os.pathsep + os.environ["PATH"], STUB_LOG=self.log,
                        XDG_CONFIG_HOME=self.cfg, XDG_DATA_HOME=os.path.join(self.tmp, "data"))
        # In-process module calls (write tests) read the same locations.
        os.environ.update(XDG_CONFIG_HOME=self.cfg, XDG_DATA_HOME=self.env["XDG_DATA_HOME"])
        self.addCleanup(lambda: [os.environ.pop(k, None) for k in ("XDG_CONFIG_HOME", "XDG_DATA_HOME")])

    def tearDown(self):
        for c in self.calls():
            if c[0] == "hyprctl" and c[1] == "dispatch" and "window.close" in c[2]:
                self.assertRegex(c[2], r'window = "address:0x[0-9a-fA-F]+"', "close without a valid address")

    # -- helpers --
    def put_dock(self, text):
        os.makedirs(os.path.dirname(self.dockfile), exist_ok=True)
        with open(self.dockfile, "w") as f:
            f.write(text)

    def read_text(self):
        with open(self.dockfile) as f:
            return f.read()

    def read_dock(self):
        with open(self.dockfile) as f:
            return json.load(f)

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return [json.loads(line) for line in f]

    def run_helper(self, script, args, active, shell_down):
        env = dict(self.env)
        if active is not None:
            env["STUB_ACTIVE"] = active
        if shell_down:
            env["STUB_SHELL_DOWN"] = "1"
        r = subprocess.run([sys.executable, "-I", os.path.join(BIN, script), *args], env=env,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def dock(self, active=None, shell_down=False, dock=None):
        if dock is not None:
            self.put_dock(dock)
        self.run_helper("omatray-dock", [], active, shell_down)

    def close(self, active=None, shell_down=False, dock=None, force=False):
        if dock is not None:
            self.put_dock(dock)
        self.run_helper("omatray-close", ["--force"] if force else [], active, shell_down)

    def undock(self, active=None, shell_down=False, dock=None):
        if dock is not None:
            self.put_dock(dock)
        self.run_helper("omatray-undock", [], active, shell_down)

    def of(self, name):
        return [c for c in self.calls() if c[0] == name]

    def closes(self):
        return [c for c in self.of("hyprctl") if c[1] == "dispatch" and "window.close" in c[2]]

    def moves(self):
        return [c for c in self.of("hyprctl") if c[1] == "dispatch" and "window.move" in c[2]]

    def hides(self):
        """Parks: moves to the tray workspace."""
        return [c for c in self.moves() if "special:omatray" in c[2]]

    def docked_dock(self, cls=OUTLOOK_WORK, app_id="outlook-work"):
        return json.dumps({"apps": [{"id": app_id, "name": "Outlook", "matchClass": cls,
                                     "desktopId": "Outlook"}]})

    # -- dock --
    def test_dock_new_chromium_appends_entry_then_parks(self):
        self.dock(active=window(OUTLOOK_WORK))
        (e,) = self.read_dock()["apps"]
        self.assertEqual(e, {"id": "outlook-work", "name": "Outlook", "matchClass": OUTLOOK_WORK,
                             "desktopId": "Outlook", "url": "https://outlook.office.com/mail/",
                             "profile": "Work", "icon": "outlook"})
        self.assertIsNone(d.validate_app(e))
        self.assertEqual(len(self.moves()), 1)
        self.assertIn("special:omatray", self.moves()[0][2])
        self.assertEqual(self.closes(), [])

    def test_dock_twice_does_not_duplicate(self):
        self.dock(active=window(GMAIL))
        self.dock(active=window(GMAIL))
        self.assertEqual([a["id"] for a in self.read_dock()["apps"]], ["gmail"])
        self.assertEqual(len(self.hides()), 2)

    def test_dock_two_profiles_two_entries(self):
        self.dock(active=window(OUTLOOK_WORK))
        self.dock(active=window(OUTLOOK_DEFAULT))
        apps = self.read_dock()["apps"]
        self.assertEqual([(a["id"], a["profile"], a["desktopId"]) for a in apps],
                         [("outlook-work", "Work", "Outlook"), ("outlook-personal", "Default", "Outlook Personal")])

    def test_dock_id_clash_gets_suffix(self):
        self.put_dock(json.dumps({"apps": [{"id": "gmail", "name": "x", "matchClass": "other", "url": "https://x.example"}]}))
        self.dock(active=window(GMAIL))
        self.assertEqual([a["id"] for a in self.read_dock()["apps"]], ["gmail", "gmail-2"])

    def test_dock_class_match_is_case_insensitive_for_desktop(self):
        self.dock(active=window("chrome-Mail.Google.Com__-Default"))
        self.assertEqual(self.read_dock()["apps"][0]["desktopId"], "Gmail")

    def test_dock_unknown_bare_host_uses_url(self):
        self.dock(active=window("chrome-example.org__-Default"))
        (e,) = self.read_dock()["apps"]
        self.assertEqual((e["name"], e["url"], e["profile"]), ("example.org", "https://example.org/", "Default"))
        self.assertIsNone(d.validate_app(e))

    def test_dock_unknown_with_path_is_refused(self):
        self.dock(active=window("chrome-example.org__a_b_-Default"))
        self.assertFalse(os.path.exists(self.dockfile))
        self.assertEqual(len(self.of("notify-send")), 1)
        self.assertEqual(self.hides(), [])

    def test_dock_already_docked_only_hides(self):
        text = self.docked_dock()
        self.dock(active=window(OUTLOOK_WORK), dock=text)
        self.assertEqual(self.read_text(), text)
        self.assertEqual(len(self.hides()), 1)
        self.assertIn('address:%s' % ADDR, self.hides()[0][2])
        self.assertEqual(self.of("notify-send"), [])

    def test_dock_shell_down_moves_window_directly(self):
        self.dock(active=window(GMAIL), shell_down=True)
        self.assertEqual(len(self.moves()), 1)
        self.assertIn('window = "address:%s"' % ADDR, self.moves()[0][2])
        self.assertIn('workspace = "special:omatray"', self.moves()[0][2])
        self.assertEqual(self.closes(), [])

    def test_dock_non_chromium_notifies_only(self):
        for cls in ("Alacritty", "libreoffice-writer"):
            self.dock(active=window(cls))
        self.assertFalse(os.path.exists(self.dockfile))
        self.assertEqual(len(self.of("notify-send")), 2)
        self.assertEqual(self.hides() + self.closes() + self.moves(), [])

    def test_dock_no_window(self):
        for out in ("", "{}", "not json", json.dumps({"address": "", "class": "chrome-x"})):
            self.dock(active=out)
        self.assertEqual(len(self.of("notify-send")), 4)
        self.assertFalse(os.path.exists(self.dockfile))
        self.assertEqual(self.hides() + self.closes() + self.moves(), [])

    def test_dock_malformed_file_untouched(self):
        for text in ("{ not json", '{"apps": 3}', "[]"):
            self.dock(active=window(GMAIL), dock=text)
            self.assertEqual(self.read_text(), text)
        self.assertEqual(len(self.of("notify-send")), 3)
        self.assertEqual(self.hides() + self.moves(), [])

    def test_dock_keeps_invalid_entries_already_in_file(self):
        self.put_dock(json.dumps({"apps": [{"id": "BAD"}]}))
        self.dock(active=window(GMAIL))
        self.assertEqual(len(self.read_dock()["apps"]), 2)

    # -- close --
    def test_close_docked_parks_fresh_address(self):
        # The helper moves the address it just read; the widget's copy may be stale.
        self.close(active=window(OUTLOOK_WORK), dock=self.docked_dock())
        self.assertEqual(len(self.hides()), 1)
        self.assertIn('address:%s' % ADDR, self.hides()[0][2])
        self.assertEqual(self.of("omarchy-shell")[-1], ["omarchy-shell", "-q", "omatray", "refresh"])
        self.assertEqual(self.closes(), [])

    def test_close_non_docked_closes_by_address(self):
        self.close(active=window("Alacritty"), dock=self.docked_dock())
        self.assertEqual(len(self.closes()), 1)
        self.assertIn('address:%s' % ADDR, self.closes()[0][2])
        self.assertEqual(self.hides(), [])

    def test_close_no_dock_file_closes(self):
        self.close(active=window("Alacritty"))
        self.assertEqual(len(self.closes()), 1)

    def test_close_no_window_does_nothing(self):
        for out in ("", "{}", "garbage", json.dumps({"address": "", "class": "x"}),
                    json.dumps({"address": "address:", "class": "x"})):
            self.close(active=out, dock=self.docked_dock())
            self.close(active=out, force=True)
        self.assertEqual(self.closes() + self.hides(), [])

    def test_close_shell_down_falls_back_to_close(self):
        self.close(active=window(OUTLOOK_WORK), dock=self.docked_dock(), shell_down=True)
        self.assertEqual(len(self.closes()), 1)
        self.assertEqual(self.moves(), [])

    def test_close_malformed_file_closes_as_non_docked(self):
        self.close(active=window(OUTLOOK_WORK), dock="{ nope")
        self.assertEqual(len(self.closes()), 1)
        self.assertEqual(self.hides(), [])
        self.assertEqual(self.read_text(), "{ nope")

    def test_force_close_docked_closes_and_keeps_entry(self):
        text = self.docked_dock()
        self.close(active=window(OUTLOOK_WORK), dock=text, force=True)
        self.assertEqual(len(self.closes()), 1)
        self.assertEqual(self.hides(), [])
        self.assertEqual(self.read_text(), text)

    # -- undock --
    def test_undock_docked_removes_entry_then_close_is_real(self):
        self.undock(active=window(OUTLOOK_WORK), dock=self.docked_dock())
        self.assertEqual(self.read_dock(), {"apps": []})
        self.assertEqual(self.hides() + self.closes() + self.moves(), [])
        self.assertIn(["omarchy-shell", "-q", "omatray", "refresh"], self.calls())
        self.close(active=window(OUTLOOK_WORK))
        self.assertEqual(len(self.closes()), 1)
        self.assertIn("address:%s" % ADDR, self.closes()[0][2])
        self.assertEqual(self.hides(), [])

    def test_undock_keeps_other_and_invalid_entries(self):
        text = json.dumps({"apps": [
            {"id": "BAD"},
            {"id": "gmail", "name": "Gmail", "matchClass": GMAIL, "url": "https://mail.google.com"},
            {"id": "outlook-work", "name": "Outlook", "matchClass": OUTLOOK_WORK, "desktopId": "Outlook"},
            {"id": "outlook-work", "name": "Dup", "matchClass": "x", "url": "https://x.example"}]})
        self.undock(active=window(OUTLOOK_WORK), dock=text)
        self.assertEqual([a["id"] for a in self.read_dock()["apps"]], ["BAD", "gmail"])

    def test_undock_non_docked_notifies_only(self):
        text = self.docked_dock()
        self.undock(active=window("Alacritty"), dock=text)
        self.assertEqual(self.read_text(), text)
        self.assertEqual(len(self.of("notify-send")), 1)
        self.assertEqual(self.hides() + self.closes() + self.moves(), [])

    def test_undock_no_window(self):
        text = self.docked_dock()
        for out in ("", "{}", json.dumps({"address": "", "class": OUTLOOK_WORK})):
            self.undock(active=out, dock=text)
        self.assertEqual(self.read_text(), text)
        self.assertEqual(len(self.of("notify-send")), 3)
        self.assertEqual(self.hides() + self.closes() + self.moves(), [])

    def test_undock_malformed_file_untouched(self):
        for text in ("{ not json", '{"apps": 3}'):
            self.undock(active=window(OUTLOOK_WORK), dock=text)
            self.assertEqual(self.read_text(), text)
        self.assertEqual(len(self.of("notify-send")), 2)

    def test_undock_shell_down_still_edits_file(self):
        self.undock(active=window(OUTLOOK_WORK), dock=self.docked_dock(), shell_down=True)
        self.assertEqual(self.read_dock(), {"apps": []})
        self.assertEqual(self.closes() + self.moves(), [])

    # -- module --
    def test_window_class_derivation(self):
        self.assertEqual(d.window_class("https://outlook.office.com/mail/", "Work"), OUTLOOK_WORK)
        self.assertEqual(d.window_class("https://mail.google.com", "Default"), GMAIL)

    def test_make_id_always_valid(self):
        for name, prof in (("Ünï cödé!!", ""), ("", "Work"), ("a" * 200, "Profile 1"), ("--", "--")):
            self.assertRegex(d.make_id(name, prof, set()), d.ID_RE.pattern)

    def test_write_failure_leaves_original_intact(self):
        self.put_dock('{"apps": []}')
        with self.assertRaises(TypeError):
            d.write_dock({"apps": [object()]})
        self.assertEqual(self.read_text(), '{"apps": []}')
        self.assertEqual(os.listdir(os.path.dirname(self.dockfile)), ["omatray.json"])

    def test_write_failure_midway_cleans_temp(self):
        self.put_dock('{"apps": []}')
        real = os.replace
        os.replace = lambda *a: (_ for _ in ()).throw(OSError("boom"))
        try:
            with self.assertRaises(OSError):
                d.write_dock({"apps": []})
        finally:
            os.replace = real
        self.assertEqual(os.listdir(os.path.dirname(self.dockfile)), ["omatray.json"])
        self.assertEqual(self.read_text(), '{"apps": []}')



    # -- review fixes --
    def test_validate_rejects_trailing_newline(self):
        # Python's `$` matches before a final newline; the widget's JS does not.
        e = {"id": "abc", "name": "A", "matchClass": "chrome-a", "url": "https://a/"}
        self.assertIsNone(d.validate_app(e))
        for k in ("id", "matchClass", "url"):
            self.assertIsNotNone(d.validate_app(dict(e, **{k: e[k] + "\n"})), k)
        self.assertIsNone(d.ADDRESS_RE.fullmatch("0x1\n"))

    def test_name_length_counts_utf16_units(self):
        e = {"id": "abc", "name": "\U0001F600" * 40, "matchClass": "chrome-a", "url": "https://a/"}
        self.assertIsNotNone(d.validate_app(e))  # 80 UTF-16 units: the widget rejects it too
        self.assertIsNone(d.validate_app(dict(e, name="\U0001F600" * 32)))

    def test_window_class_ignores_port_and_userinfo(self):
        self.assertEqual(d.window_class("https://u@host.example:8443/x/", "Work"), "chrome-host.example__x_-Work")

    def test_close_popout_of_docked_app_closes_it(self):
        self.env["STUB_CLIENTS"] = json.dumps([{"address": "0xmain1", "class": OUTLOOK_WORK},
                                               {"address": ADDR, "class": OUTLOOK_WORK}])
        self.close(active=window(OUTLOOK_WORK), dock=self.docked_dock())
        self.assertEqual(self.hides(), [])
        self.assertEqual(len(self.closes()), 1)
        self.assertIn(ADDR, self.closes()[0][2])

    def test_close_main_window_of_docked_app_hides(self):
        self.env["STUB_CLIENTS"] = json.dumps([{"address": ADDR, "class": OUTLOOK_WORK},
                                               {"address": "0xpop1", "class": OUTLOOK_WORK}])
        self.close(active=window(OUTLOOK_WORK), dock=self.docked_dock())
        self.assertEqual(len(self.hides()), 1)
        self.assertEqual(self.closes(), [])

    def test_dock_popout_notifies_and_changes_nothing(self):
        self.env["STUB_CLIENTS"] = json.dumps([{"address": "0xmain1", "class": GMAIL},
                                               {"address": ADDR, "class": GMAIL}])
        self.dock(active=window(GMAIL))
        self.assertFalse(os.path.exists(self.dockfile))
        self.assertEqual((self.moves(), self.hides(), self.closes()), ([], [], []))
        self.assertEqual(len(self.of("notify-send")), 1)

    def test_pinned_window_is_used_instead_of_focus(self):
        self.env["OMATRAY_WINDOW"] = "0xfeed"
        self.env["STUB_CLIENTS"] = json.dumps([{"address": "0xfeed", "class": "Alacritty"}])
        self.close(active=window("Alacritty", addr="0xbad"))
        self.assertEqual(len(self.closes()), 1)
        self.assertIn("0xfeed", self.closes()[0][2])

    def test_pinned_window_missing_does_nothing(self):
        self.env["OMATRAY_WINDOW"] = "0xgone"
        self.env["STUB_CLIENTS"] = "[]"
        self.close(active=window("Alacritty"))
        self.assertEqual(self.closes(), [])

if __name__ == "__main__":
    unittest.main()
