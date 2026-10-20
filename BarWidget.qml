import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Dock-style control for a Chromium web app, modelled on the macOS Dock:
//   - the icon is always present, like a Dock tile
//   - a badge carries the unread count, read from the window title
//   - hiding parks the window on a special workspace instead of quitting,
//     which is what Cmd+H does on macOS
//   - closing (SUPER+W) hides too, so the app keeps running in the background
//   - right-clicking opens a menu; quitting for real lives in there, because a
//     right-click that closes the app without asking is not a thing anyone expects
Panel {
  id: root
  moduleName: "io.github.gumbledore.omatray"
  ipcTarget: "omatray"
  // Panel's built-in IPC would claim show/hide/toggle for the *popup*. Those
  // names are already spoken for here -- omatray-close calls them meaning the
  // app *window* -- so this widget keeps its own handler.
  manageIpc: false

  // Panel, unlike BarWidget, has no broadcast(). An IPC target routes to a
  // single handler but a bar surface exists per monitor, so without this a
  // refresh would update one screen and leave the others stale.
  function broadcast(method) {
    var items = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && typeof items[i][method] === "function") items[i][method]()
    }
  }

  // ---- settings ----
  //
  // Every one of these reaches a command line, so each is checked against a
  // strict pattern and falls back to its default when it does not match. This
  // is the second line of defence -- commands are built as argv vectors rather
  // than shell strings (see runArgv) -- but a setting that cannot express
  // anything but its intended shape is a much smaller thing to reason about.
  function settingMatching(name, fallback, pattern) {
    var value = String(setting(name, fallback))
    return pattern.test(value) ? value : fallback
  }

  readonly property string appUrl: settingMatching(
    "url", "https://web.whatsapp.com", /^https?:\/\/[A-Za-z0-9._~:\/?#\[\]@!$&'()*+,;=%-]+$/)

  // Must be non-empty: this is used with indexOf(), and "" is a substring of
  // every string, so an empty fragment would match every window on the system.
  readonly property string matchClass: settingMatching(
    "matchClass", "chrome-web.whatsapp.com", /^[A-Za-z0-9._-]+$/).toLowerCase()

  // Until the dock list exists, the widget drives this one web app.
  function launchArgv() {
    return ["omarchy-launch-or-focus-webapp", root.matchClass, root.appUrl]
  }

  readonly property int pollInterval: Math.max(500, Number(setting("pollInterval", 2000)))
  readonly property string hideWorkspace: "special:omatray"

  // ---- window state, refreshed from hyprctl ----
  property string winAddress: ""
  property string winTitle: ""
  property string winWorkspace: ""

  readonly property bool running: winAddress !== ""
  readonly property bool hidden: running && winWorkspace.indexOf("special:") === 0

  // Forces a count so the badge can be looked at on demand. Otherwise the only
  // way to see it is to wait for somebody to message you, which is how it went
  // unverified for so long. `omarchy bar set io.github.gumbledore.omatray debugUnread 3`.
  readonly property int debugUnread: Math.max(0, Number(setting("debugUnread", 0)))

  // Many web apps put the unread count at the head of the title: "(3) Chat | ..."
  readonly property int unread: {
    if (root.debugUnread > 0) return root.debugUnread
    var m = /^\((\d+)\)/.exec(root.winTitle)
    return m ? parseInt(m[1], 10) : 0
  }

  readonly property var activeToplevel: ToplevelManager.activeToplevel
  readonly property bool focused: {
    var t = root.activeToplevel
    if (!t) return false
    return String(t.appId || "").toLowerCase().indexOf(root.matchClass) >= 0
  }


  // ---- actions ----
  // Commands are run as an argv vector, never as a shell string. bar.run() goes
  // through Util.execDetached, which is `bash -lc <command>` -- so anything
  // interpolated into it is shell syntax, and these values come from settings
  // the user edits. Util.execArgv runs `bash -lc 'exec "$@"'` instead, where
  // arguments land in positional parameters and are never re-tokenized.
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
  // ("dispatch movetoworkspacesilent ws,address:0x...") is rejected outright,
  // so every dispatch below is built as a Lua expression.
  function dispatch(lua) {
    root.runArgv(["hyprctl", "dispatch", lua])
  }

  function moveLua(workspace) {
    return "hl.dsp.window.move({ window = " + root.luaStr("address:" + root.winAddress)
         + ", workspace = " + root.luaStr(workspace) + ", follow = false })"
  }

  function showApp() {
    if (!root.running) {
      root.runArgv(root.launchArgv())
      probeSoon()
      return
    }
    var target = String(Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1)

    root.dispatch(root.moveLua(target))
    root.dispatch("hl.dsp.focus({ window = " + root.luaStr("address:" + root.winAddress) + " })")

    probeSoon()
  }

  // Actually quit the app, as opposed to parking it. This is the only way out
  // now that SUPER+W hides instead of closing, so it lives on right-click.
  //
  // The address guard is not paranoia: hl.dsp.window.close() falls back to the
  // *active* window when handed an empty address, so an unset winAddress would
  // close whatever the user happens to be looking at.
  function quitApp() {
    if (!root.running || root.winAddress === "") return
    root.dispatch("hl.dsp.window.close({ window = "
                  + root.luaStr("address:" + root.winAddress) + " })")
    probeSoon()
  }

  function hideApp() {
    if (!root.running || root.hidden) return
    root.dispatch(root.moveLua(root.hideWorkspace))
    probeSoon()
  }

  // Dock behaviour: bring it to the front, or tuck it away if it is already there.
  function toggleApp() {
    if (!root.running || root.hidden) showApp()
    else if (root.focused) hideApp()
    else showApp()
  }


  function probeSoon() { settleTimer.restart() }

  // ---- window probe ----
  function applyClients(raw) {
    var addr = "", title = "", ws = ""
    try {
      var list = JSON.parse(raw)
      for (var i = 0; i < list.length; i++) {
        var c = list[i]
        if (String(c.class || "").toLowerCase().indexOf(root.matchClass) >= 0) {
          addr = String(c.address || "")
          title = String(c.title || "")
          ws = c.workspace ? String(c.workspace.name || "") : ""
          break
        }
      }
    } catch (e) {
      return // keep the last good reading rather than flapping the UI
    }
    root.winAddress = addr
    root.winTitle = title
    root.winWorkspace = ws
  }

  Process {
    id: probe
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: root.applyClients(String(text || ""))
    }
  }

  function refresh() { if (!probe.running) probe.running = true }

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

  IpcHandler {
    target: "omatray"
    function toggle(): void { root.broadcast("toggleApp") }
    function show(): void { root.broadcast("showApp") }
    function hide(): void { root.broadcast("hideApp") }
    function quit(): void { root.broadcast("quitApp") }
    function menu(): void { root.toggle() }
    function refresh(): void { root.broadcast("refresh") }
  }

  // ---- presentation ----
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(0xF0AEE) // nf-md-dock_window
    opacity: root.running ? 1.0 : 0.45
    tooltipText: {
      if (!root.running) return "omatray — not running (click to open)"
      var bits = []
      bits.push(root.hidden ? "omatray — hidden" : "omatray")
      if (root.unread > 0) bits.push(root.unread + " unread")
      return bits.join(" · ")
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggle()
      else root.toggleApp()
    }

    Behavior on opacity {
      NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
    }
  }

  // ---- the menu ----
  // Anchored to the icon and opened on right-click. Everything destructive or
  // non-obvious lives here rather than on a mouse button nobody would guess.
  readonly property string stateLine: {
    if (!root.running) return "Not running"
    var bits = [root.hidden ? "Hidden" : "Visible"]
    if (root.unread > 0) bits.push(root.unread + " unread")
    return bits.join(" · ")
  }

  KeyboardPanel {
    id: menuPanel
    anchorItem: button
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
        if (k === "h") { root.toggleApp(); root.close() }
        else if (k === "q") { root.quitApp(); root.close() }
      }

      Column {
        id: menuColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // Header: what the app is doing right now.
        Column {
          width: parent.width
          spacing: Style.space(2)

          Text {
            text: "omatray"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
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
          enabled: root.running
          iconText: root.hidden ? String.fromCodePoint(0xF06D0) : String.fromCodePoint(0xF06D1)
          text: root.hidden ? "Show app" : "Hide app"
          fontSize: Style.font.bodySmall
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: { root.toggleApp(); root.close() }
        }

        Button {
          width: parent.width
          leftAlign: true
          bordered: true
          enabled: root.running
          iconText: String.fromCodePoint(0xF0206)
          text: "Quit app"
          fontSize: Style.font.bodySmall
          // Urgent, because this one actually kills the app rather than parking it.
          foreground: Color.urgent
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: { root.quitApp(); root.close() }
        }
      }
    }
  }

  // Unread badge, in the top-right corner like a Dock tile.
  //
  // Sized against Style.bar.iconSlot (27px by default), not picked by eye: at
  // the original Style.space(13) the badge was half the slot and swallowed the
  // glyph it was supposed to annotate. A Dock badge sits at roughly a third of
  // the tile, and the ring in background colour is what keeps it legible where
  // it does overlap.
  Rectangle {
    id: badge
    visible: root.unread > 0
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: 0
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
      text: root.unread > 99 ? "99+" : String(root.unread)
      color: Color.background
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Math.max(7, Style.font.caption - 3)
      font.bold: true
    }
  }

  // Presence dot: the app has a visible window.
  Rectangle {
    id: presenceDot
    visible: root.running && !root.hidden
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