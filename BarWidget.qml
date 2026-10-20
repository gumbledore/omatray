pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Ui

// Dock for web apps, modeled on the macOS Dock. The docked apps come from
// ~/.config/omarchy/omatray.json, one bar icon each, in file order:
//   - an icon is always present, like a Dock tile; a not-running app is dimmed
//   - a badge carries the unread count, read from the window title
//   - hiding parks the window on a special workspace instead of quitting,
//     which is what Cmd+H does on macOS
//   - left-click shows / hides / launches; right-click opens a per-app menu,
//     because quitting without asking is not something a click should do
Panel {
  id: root
  moduleName: "io.github.gumbledore.omatray"
  ipcTarget: "omatray"
  // Panel's built-in IPC would claim show/hide/toggle for the *popup*. Those
  // names are already spoken for here -- they mean the app *window* -- so this
  // widget keeps its own handler.
  manageIpc: false

  // Panel, unlike BarWidget, has no broadcast(). A bar surface exists per
  // monitor, so state refreshes must reach every instance. Window *actions* are
  // deliberately not broadcast: each instance would run the same dispatch and
  // the window would be moved N times. An action runs once, on the instance
  // that received it, and only the follow-up re-probe is broadcast.
  function broadcast(method) {
    var items = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && typeof items[i][method] === "function") items[i][method]()
    }
  }

  readonly property int pollInterval: Math.max(500, Number(setting("pollInterval", 2000)))
  readonly property string hideWorkspace: "special:omatray"
  readonly property int genericGlyph: 0xF08C6 // nf-md-application

  // ---- dock file ----
  //
  // Every value read from the file ends up in a command line or a Lua
  // expression, so each is checked against a strict pattern first and an entry
  // with a bad required field is skipped. Commands are also built as argv
  // vectors (see runArgv), so this is the second line of defense.
  //
  // dock-validate:begin (self-contained; exercised from node by extracting this block)
  function validateApp(a) {
    if (!a || typeof a !== "object" || Array.isArray(a)) return { error: "not an object" }
    function str(v) { return typeof v === "string" ? v : "" }
    var id = str(a.id), name = str(a.name), mc = str(a.matchClass)
    var desktopId = a.desktopId === undefined ? "" : str(a.desktopId)
    var url = a.url === undefined ? "" : str(a.url)
    var profile = a.profile === undefined ? "" : str(a.profile)
    if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(id)) return { error: "bad id" }
    if (name.length < 1 || name.length > 64 || /[\u0000-\u001f\u007f]/.test(name)) return { error: "bad name" }
    // Exact, case-insensitive class match later on; an empty class must never exist.
    if (!/^[A-Za-z0-9._-]+$/.test(mc)) return { error: "bad matchClass" }
    // A leading "-" would reach gtk-launch as an option.
    if (desktopId !== "" && !(/^[A-Za-z0-9._ -]{1,128}$/.test(desktopId) && desktopId.charAt(0) !== "-"))
      return { error: "bad desktopId" }
    if (url !== "" && !/^https?:\/\/[A-Za-z0-9._~:\/?#\[\]@!$&'()*+,;=%-]+$/.test(url))
      return { error: "bad url" }
    if (profile !== "" && !/^[A-Za-z0-9 _-]{1,64}$/.test(profile)) return { error: "bad profile" }
    if (desktopId === "" && url === "") return { error: "needs desktopId or url" }
    // An invalid icon is not fatal: the entry still works with the generic glyph.
    var icon = { kind: "glyph", value: "" }
    var raw = str(a.icon)
    if (/^\/[A-Za-z0-9._\/ +-]+$/.test(raw)) icon = { kind: "path", value: raw }
    else if (/^[A-Za-z0-9._+-]+$/.test(raw)) icon = { kind: "theme", value: raw }
    else if (raw !== "" && Array.from(raw).length === 1 && !/[\s\u0000-\u001f\u007f]/.test(raw))
      icon = { kind: "glyph", value: raw }
    // Carried as text; compiled by applyDock (see compileUnread).
    var unreadPattern = str(a.unreadPattern)
    if (unreadPattern.length > 128) unreadPattern = ""
    return { app: { id: id, name: name, matchClass: mc, desktopId: desktopId, url: url,
                    profile: profile, icon: icon, unreadPattern: unreadPattern } }
  }

  function parseDock(text) {
    var apps = [], warnings = [], seen = {}
    var doc
    try { doc = JSON.parse(text) } catch (e) { return { apps: apps, warnings: ["unparseable JSON: " + e] } }
    if (!doc || !Array.isArray(doc.apps)) return { apps: apps, warnings: ["'apps' is not an array"] }
    for (var i = 0; i < doc.apps.length; i++) {
      var r = validateApp(doc.apps[i])
      if (r.error) { warnings.push("skipping entry " + i + ": " + r.error); continue }
      if (seen[r.app.id]) { warnings.push("skipping entry " + i + ": duplicate id " + r.app.id); continue }
      seen[r.app.id] = true
      apps.push(r.app)
    }
    return { apps: apps, warnings: warnings }
  }
  // dock-validate:end

  // ---- unread count ----
  // Web apps put the count in the window title. Default: the first "(N)"
  // anywhere ("Inbox (3) - ..." and "(3) Chat | ..." both read 3). A per-app
  // unreadPattern replaces it; it needs one capture group holding digits.
  //
  // unread:begin (pure; exercised from node by extracting this block)
  function compileUnread(pattern) {
    var def = /\((\d+)\)/
    if (pattern === "") return { re: def, bad: false }
    try {
      var re = new RegExp(pattern)
      // Appending an always-matching alternative exposes the group count.
      if (new RegExp("(?:" + pattern + ")|").exec("").length < 2) return { re: def, bad: true }
      return { re: re, bad: false }
    } catch (e) {
      return { re: def, bad: true }
    }
  }

  // A capture that is not digits falls back to the default for that title.
  function unreadCount(re, title) {
    var m = re.exec(title)
    if (m && /^\d+$/.test(m[1])) return parseInt(m[1], 10)
    if (m) m = /\((\d+)\)/.exec(title)
    return m ? parseInt(m[1], 10) : 0
  }

  function badgeText(n) { return n > 99 ? "99+" : String(n) }
  // unread:end

  readonly property string dockPath: {
    var xdg = Quickshell.env("XDG_CONFIG_HOME")
    var base = xdg ? xdg : Quickshell.env("HOME") + "/.config"
    return base + "/omarchy/omatray.json"
  }

  property var apps: []
  // Last text applied, so the poll-tick reload below only rebuilds the icons
  // when the file really changed. null = nothing read yet; "\0" = missing.
  property var lastDockText: null

  function applyDock(text) {
    if (text === root.lastDockText) return
    root.lastDockText = text
    var r = root.parseDock(text)
    for (var i = 0; i < r.warnings.length; i++) console.warn("omatray: " + root.dockPath + ": " + r.warnings[i])
    // Compiled once per (re)load, not per title. Warns once, since applyDock
    // only runs when the file text changed.
    for (var j = 0; j < r.apps.length; j++) {
      var c = root.compileUnread(r.apps[j].unreadPattern)
      if (c.bad) console.warn("omatray: " + r.apps[j].id + ": unreadPattern needs one capture group and must be a valid regex; using the default")
      r.apps[j].unreadRe = c.re
    }
    root.apps = r.apps
    root.probeSoon()
  }

  FileView {
    id: dockFile
    path: root.dockPath
    atomicWrites: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyDock(String(text() || ""))
    onLoadFailed: {
      if (root.lastDockText !== "\0") console.warn("omatray: no dock file at " + root.dockPath + " (empty bar)")
      root.lastDockText = "\0"
      root.apps = []
    }
  }

  function appById(id) {
    for (var i = 0; i < root.apps.length; i++) if (root.apps[i].id === id) return root.apps[i]
    return null
  }

  // ---- window state, refreshed from hyprctl ----
  // id -> { address, title, workspace } for apps that have a window; absent otherwise.
  property var winStates: ({})
  property string lastStatesKey: ""

  function stateOf(id) { return root.winStates[id] || null }
  function isRunning(id) { return root.stateOf(id) !== null }
  function isHidden(id) {
    var s = root.stateOf(id)
    return s !== null && s.workspace === root.hideWorkspace
  }

  // Forces this count onto every docked app so the badge can be looked at on
  // demand (0 = off). Deliberately a shell.json setting, not in the manifest
  // schema: it is a debugging aid, not something to offer in the settings UI.
  // `omarchy bar set io.github.gumbledore.omatray debugUnread 3`.
  readonly property int debugUnread: Math.max(0, Number(setting("debugUnread", 0)))

  function unreadOf(id) {
    if (root.debugUnread > 0) return root.debugUnread
    var s = root.stateOf(id), app = root.appById(id)
    return s && app ? root.unreadCount(app.unreadRe, s.title) : 0
  }

  // One wording for tooltip and menu header so they cannot drift apart.
  function stateWord(id) {
    return !root.isRunning(id) ? "not running" : root.isHidden(id) ? "hidden" : "visible"
  }
  function unreadSuffix(id) {
    var n = root.unreadOf(id)
    return n > 0 ? " · " + n + " unread" : ""
  }

  readonly property var activeToplevel: ToplevelManager.activeToplevel
  function isFocused(app) {
    var t = root.activeToplevel
    return !!t && String(t.appId || "").toLowerCase() === app.matchClass.toLowerCase()
  }

  // hyprctl hands out addresses as 0x<hex>. Anything else is treated as "no
  // window", which also keeps the close guard below honest.
  function addressOf(id) {
    var s = root.stateOf(id)
    return s && /^0x[0-9a-fA-F]+$/.test(s.address) ? s.address : ""
  }

  // ---- actions ----
  // Commands are run as an argv vector, never as a shell string. bar.run() goes
  // through Util.execDetached, which is `bash -lc <command>` -- so anything
  // interpolated into it is shell syntax. Util.execArgv runs
  // `bash -lc 'exec "$@"'` instead, where arguments land in positional
  // parameters and are never re-tokenized.
  function runArgv(argv) {
    Util.execArgv(argv)
  }

  // Belt and braces for the Lua layer: the dispatch argument is a single argv
  // element so the shell never sees it, but a stray quote would still break the
  // Lua expression itself.
  function luaStr(value) {
    return '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
  }

  // Omarchy 4 drives Hyprland through its Lua dispatch API. The pre-Lua form
  // ("dispatch movetoworkspacesilent ws,address:0x...") is rejected outright.
  function dispatch(lua) {
    root.runArgv(["hyprctl", "dispatch", lua])
  }

  // follow = false: moving a window must never drag the user's view with it.
  function moveLua(address, workspace) {
    return "hl.dsp.window.move({ window = " + root.luaStr("address:" + address)
         + ", workspace = " + root.luaStr(workspace) + ", follow = false })"
  }

  // Prefer the desktop entry (it carries the profile and flags Omarchy wrote
  // into the .desktop file), launched the way the Omarchy launcher does. Fall
  // back to omarchy-launch-webapp, which forwards extra args to the browser.
  function launchArgv(app) {
    var hasEntry = app.desktopId !== "" && !!DesktopEntries.byId(app.desktopId)
    if (app.desktopId !== "" && (hasEntry || app.url === ""))
      return ["uwsm-app", "--", "gtk-launch", app.desktopId + ".desktop"]
    var argv = ["omarchy-launch-webapp", app.url]
    if (app.profile !== "") argv.push("--profile-directory=" + app.profile)
    return argv
  }

  function launchApp(app) {
    root.runArgv(root.launchArgv(app))
    root.settleAll()
  }

  // Bring one window to the workspace the user is on, without switching to it.
  function showApp(id) {
    var app = root.appById(id)
    if (!app) return
    var address = root.addressOf(id)
    if (address === "") { root.launchApp(app); return }
    var ws = String(Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1)
    root.dispatch(root.moveLua(address, ws))
    root.dispatch("hl.dsp.focus({ window = " + root.luaStr("address:" + address) + " })")
    root.settleAll()
  }

  // Minimize to the shared tray workspace. That workspace is never toggled into
  // view, so the window just disappears until shown again.
  function hideApp(id) {
    var address = root.addressOf(id)
    if (address === "" || root.isHidden(id)) return
    root.dispatch(root.moveLua(address, root.hideWorkspace))
    root.settleAll()
  }

  // Dock behavior: launch, or bring to the front, or tuck away if already there.
  function toggleApp(id) {
    var app = root.appById(id)
    if (!app) return
    if (!root.isRunning(id) || root.isHidden(id)) root.showApp(id)
    else if (root.isFocused(app)) root.hideApp(id)
    else root.showApp(id)
  }

  // Really close the window; the entry stays docked.
  //
  // The address guard is not paranoia: hl.dsp.window.close() falls back to the
  // *active* window when handed an empty address, so an unset address would
  // close whatever the user happens to be looking at.
  function quitApp(id) {
    var address = root.addressOf(id)
    if (address === "") return
    root.dispatch("hl.dsp.window.close({ window = " + root.luaStr("address:" + address) + " })")
    root.settleAll()
  }

  // Remove the entry from the dock file; the file watch then drops the icon.
  // A parked window is brought back first so it is never stranded on the tray
  // workspace. The raw text is re-parsed (not root.apps) so hand-edited entries
  // the widget rejected survive the write. Malformed file: leave it alone.
  function undockApp(id) {
    if (root.isHidden(id)) root.showApp(id)
    var doc
    try { doc = JSON.parse(String(dockFile.text() || "")) } catch (e) { doc = null }
    if (!doc || !Array.isArray(doc.apps)) {
      console.warn("omatray: undock: dock file is malformed; not changing it")
      return
    }
    doc.apps = doc.apps.filter(function(a) { return !(a && a.id === id) })
    dockFile.setText(JSON.stringify(doc, null, 2) + "\n")
  }

  function probeSoon() { settleTimer.restart() }
  function settleAll() { root.broadcast("probeSoon") }

  // ---- window probe ----
  // One hyprctl call serves every app. Per app the FIRST window whose class
  // equals matchClass (case-insensitively) wins.
  function applyClients(raw) {
    var first = {}
    try {
      var list = JSON.parse(raw)
      for (var i = 0; i < list.length; i++) {
        var key = String(list[i].class || "").toLowerCase()
        if (key !== "" && !(key in first)) first[key] = list[i]
      }
    } catch (e) {
      return // keep the last good reading rather than flapping the UI
    }
    var states = {}
    for (var j = 0; j < root.apps.length; j++) {
      var c = first[root.apps[j].matchClass.toLowerCase()]
      if (!c) continue
      states[root.apps[j].id] = {
        address: String(c.address || ""),
        title: String(c.title || ""),
        workspace: c.workspace ? String(c.workspace.name || "") : ""
      }
    }
    var k = JSON.stringify(states)
    if (k === root.lastStatesKey) return
    root.lastStatesKey = k
    root.winStates = states
  }

  Process {
    id: probe
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: root.applyClients(String(text || ""))
    }
  }

  // The dock file is replaced by rename (temp file + mv), which swaps the
  // inode a file watcher is attached to. Reloading on every tick is the
  // safety net for a watcher that loses the file; applyDock ignores unchanged text.
  function refresh() {
    dockFile.reload()
    if (!probe.running) probe.running = true
  }

  Timer {
    interval: root.pollInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: settleTimer
    interval: 250
    repeat: false
    onTriggered: root.refresh()
  }

  // An unknown id is a logged no-op. Window actions run on this instance only
  // (see broadcast); refresh is the one thing every monitor needs.
  function known(method, id) {
    if (root.appById(id)) return true
    console.warn("omatray: " + method + ": unknown app id '" + id + "'")
    return false
  }

  IpcHandler {
    target: "omatray"
    function toggle(id: string): void { if (root.known("toggle", id)) root.toggleApp(id) }
    function show(id: string): void { if (root.known("show", id)) root.showApp(id) }
    function hide(id: string): void { if (root.known("hide", id)) root.hideApp(id) }
    function quit(id: string): void { if (root.known("quit", id)) root.quitApp(id) }
    function undock(id: string): void { if (root.known("undock", id)) root.undockApp(id) }
    function menu(id: string): void { if (root.known("menu", id)) root.openMenu(id) }
    function refresh(): void { root.broadcast("refresh") }
  }

  // ---- presentation ----
  implicitWidth: tiles.implicitWidth
  implicitHeight: tiles.implicitHeight

  Grid {
    id: tiles
    columns: root.vertical ? 1 : Math.max(1, root.apps.length)

    Repeater {
      id: tileRepeater
      model: root.apps

      Item {
        id: tile
        required property var modelData
        readonly property var app: modelData
        readonly property bool running: root.isRunning(app.id)
        readonly property bool hidden: root.isHidden(app.id)
        readonly property int unread: root.unreadOf(app.id)
        property alias btn: button
        readonly property string iconUrl: app.icon.kind === "path" ? Util.fileUrl(app.icon.value)
          : app.icon.kind === "theme" ? Quickshell.iconPath(app.icon.value, true) : ""

        implicitWidth: button.implicitWidth
        implicitHeight: button.implicitHeight
        width: implicitWidth
        height: implicitHeight

        BarIconButton {
          id: button
          anchors.fill: parent
          bar: root.bar
          text: tile.iconUrl !== "" ? ""
            : String.fromCodePoint(tile.app.icon.kind === "glyph" && tile.app.icon.value !== ""
                ? tile.app.icon.value.codePointAt(0) : root.genericGlyph)
          iconComponent: tile.iconUrl !== "" ? imageIcon : null
          opacity: tile.running ? 1.0 : 0.45
          tooltipText: tile.app.name + " — " + root.stateWord(tile.app.id)
            + (tile.running ? "" : " (click to open)") + root.unreadSuffix(tile.app.id)
          onPressed: function(b) {
            if (b === Qt.RightButton) root.openMenu(tile.app.id)
            else root.toggleApp(tile.app.id)
          }

          Behavior on opacity {
            NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
          }
        }

        Component {
          id: imageIcon
          IconImage {
            anchors.fill: parent
            source: tile.iconUrl
          }
        }

        // Unread badge, in the top-right corner like a Dock tile.
        //
        // Sized against Style.bar.iconSlot (27px by default), not picked by eye:
        // a Dock badge sits at roughly a third of the tile, and the ring in
        // background color keeps it legible where it overlaps the glyph.
        Rectangle {
          visible: tile.unread > 0
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: Style.space(1)
          height: Math.round(Style.bar.iconSlot * 0.37)
          width: Math.max(height, badgeLabel.implicitWidth + Style.space(5))
          radius: height / 2
          color: Color.urgent
          border.width: 1
          border.color: Color.background
          z: 2

          Text {
            id: badgeLabel
            anchors.centerIn: parent
            text: root.badgeText(tile.unread)
            color: Color.background
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Math.max(7, Style.font.caption - 3)
            font.bold: true
          }
        }

        // Presence dot: the app has a visible window.
        Rectangle {
          visible: tile.running && !tile.hidden
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.rightMargin: Style.space(2)
          anchors.bottomMargin: Style.space(3)
          width: Style.space(7)
          height: width
          radius: width / 2
          color: Color.accent
          border.width: 1
          border.color: Color.background
          z: 2
        }
      }
    }
  }

  // ---- the menu ----
  // One panel shared by all tiles, retargeted at the app that was clicked.
  property string menuAppId: ""
  property Item menuAnchor: null
  readonly property var menuApp: root.appById(root.menuAppId)

  function openMenu(id) {
    for (var i = 0; i < root.apps.length; i++) {
      if (root.apps[i].id !== id) continue
      var tile = tileRepeater.itemAt(i)
      if (!tile) return
      root.menuAppId = id
      root.menuAnchor = tile.btn
      if (!root.opened) root.open()
      return
    }
  }

  // Primary action: launch if not running, show if parked, otherwise hide.
  function menuToggle() {
    var id = root.menuAppId
    if (!root.isRunning(id) || root.isHidden(id)) root.showApp(id)
    else root.hideApp(id)
  }

  readonly property string stateLine: {
    var id = root.menuAppId, w = root.stateWord(id)
    return w.charAt(0).toUpperCase() + w.slice(1) + root.unreadSuffix(id)
  }

  KeyboardPanel {
    id: menuPanel
    anchorItem: root.menuAnchor ? root.menuAnchor : tiles
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: menuKeys
    contentWidth: menuPanel.fittedContentWidth(Style.space(260))
    contentHeight: menuPanel.fittedContentHeight(menuColumn.implicitHeight)

    PanelKeyCatcher {
      id: menuKeys
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "h") { root.menuToggle(); root.close() }
        else if (k === "q") { root.quitApp(root.menuAppId); root.close() }
        else if (k === "u") { root.undockApp(root.menuAppId); root.close() }
      }

      Column {
        id: menuColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // Header: which app, and what it is doing right now.
        Column {
          width: parent.width
          spacing: Style.space(2)

          Text {
            text: root.menuApp ? root.menuApp.name : ""
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }
          Text {
            text: root.stateLine
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.55)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
          }
        }

        PanelSeparator { width: parent.width }

        Button {
          width: parent.width
          leftAlign: true
          bordered: true
          iconText: root.isHidden(root.menuAppId) || !root.isRunning(root.menuAppId)
            ? String.fromCodePoint(0xF06D0) : String.fromCodePoint(0xF06D1)
          text: !root.isRunning(root.menuAppId) ? "Launch"
            : root.isHidden(root.menuAppId) ? "Show" : "Hide"
          fontSize: Style.font.bodySmall
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: { root.menuToggle(); root.close() }
        }

        Button {
          width: parent.width
          leftAlign: true
          bordered: true
          enabled: root.isRunning(root.menuAppId)
          iconText: String.fromCodePoint(0xF0206)
          text: "Quit"
          fontSize: Style.font.bodySmall
          // Urgent, because this one actually closes the window rather than parking it.
          foreground: Color.urgent
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: { root.quitApp(root.menuAppId); root.close() }
        }

        Button {
          width: parent.width
          leftAlign: true
          bordered: true
          iconText: String.fromCodePoint(0xF0156)
          text: "Remove from dock"
          fontSize: Style.font.bodySmall
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: { root.undockApp(root.menuAppId); root.close() }
        }
      }
    }
  }
}
