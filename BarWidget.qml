// Omarchy Task Manager: freeze/resume memory-hogging apps.
// - Pill: tasks glyph + red badge (or live CPU/MEM stats, eye toggle).
// - Popup: draggable Overlay-layer card above all windows, all workspaces.
// - Frozen apps get a grey veil exactly over their windows.
// - Process tree per app, per-row sparklines, historical CPU/RAM graph.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "io.github.avillagran.omarchy-task-manager"

  property var apps: []
  property var frozenWins: []
  property var monitors: []
  property int frozenCount: 0
  property int memAvailMb: 0
  property int memTotalMb: 0
  property real psiSome10: 0.0
  property int swapUsedMb: 0
  property bool zswapAvailable: true
  property bool zswapEnabled: true
  property var background: []
  property bool pressureCritical: false
  property real dismissedAt: 0
  property bool cardPosSet: false
  property bool popupOpen: false
  property bool pinned: false
  property var prefs: ({})
  property var hist: ({})
  property real cpuNow: 0.0
  property real memNow: 0.0
  property var expandedProcs: ({})
  property var procsData: ({})
  property var procsQueue: []
  property int pendingProcsPid: 0
  property string binPath: (typeof manifest !== 'undefined' && manifest.__sourceDir)
                           ? manifest.__sourceDir.replace(/\/$/, '') + '/bin/task-manager-launch.sh'
                           : Qt.resolvedUrl("bin/task-manager-launch.sh").toString().replace("file://", "")

  // Icon font: an EXPLICIT Nerd Font family. Qt's "monospace" alias lets
  // fontconfig hand PUA codepoints to random fallback fonts (F0EE0 rendered
  // as a cloud-upload glyph); both FiraCode NF and JetBrainsMono NF on this
  // system cover every glyph we use, but only when named explicitly.
  property string iconFont: "JetBrainsMono Nerd Font"

  // Bar pill display mode: "off" (icon only) / "numbers" / "numbers+graph".
  // Legacy boolean barStats maps to off/numbers.
  property string barMode: {
    var m = root.prefs["barMode"]
    if (m === "off" || m === "numbers" || m === "graph") return m
    return root.pref("barStats", false) ? "numbers" : "off"
  }
  function cycleBarMode() {
    var next = barMode === "off" ? "numbers" : (barMode === "numbers" ? "graph" : "off")
    setPref("barMode", next)
  }

  // Card geometry, persisted across sessions.
  property int cardW: parseInt(root.prefs["cardW"] || "560") || 560
  property int cardH: parseInt(root.prefs["cardH"] || "640") || 640

  // Width per mode, FIXED within each mode (digits are fixed-width, so 9→10
  // never jitters). "off" shrinks to the icon so the bar packs it naturally.
  implicitWidth: barMode === "off" ? 30 : (barMode === "graph" ? 178 : 108)
  implicitHeight: barSize

  // --- i18n (same self-contained pattern as omarchy-x-panel) ---------------
  property var i18n: ({})
  property string lang: {
    var l = Quickshell.env("LANGUAGE") || Quickshell.env("LANG") || "en"
    l = l.split(":")[0].split(".")[0].split("_")[0]
    return l || "en"
  }
  function tr(k) {
    if (root.i18n[root.lang] && root.i18n[root.lang][k] !== undefined) return root.i18n[root.lang][k]
    if (root.i18n["en"] && root.i18n["en"][k] !== undefined) return root.i18n["en"][k]
    return k
  }
  Process {
    id: i18nLoader
    command: ["bash", "-lc", "head -c 262144 '" + Qt.resolvedUrl("i18n.json").toString().replace("file://", "") + "'"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.i18n = JSON.parse(text || "{}") } catch (e) {} }
    }
  }

  // Icon toggle button with an explicit monospace (Nerd Font) glyph —
  // qs.Ui Button's font has no MDI private-use glyphs (renders tofu).
  component IconBtn: Rectangle {
    property string glyph: ""
    property bool active: false
    signal clicked()
    width: 26
    height: 26
    radius: 5
    color: active ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16) : "transparent"
    border.color: active ? Color.accent
                         : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.30)
    border.width: 1
    Text {
      anchors.centerIn: parent
      text: parent.glyph
      color: parent.active ? Color.accent : Color.popups.text
      font.family: root.iconFont
      font.pixelSize: Style.font.body
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.clicked()
    }
  }

  // Compact row action button (pause/resume/kill): small, hover-lit, with
  // accent (resume) and danger (kill) variants. Replaces the chunky
  // bordered qs.Ui Buttons that dominated single-line rows.
  component RowBtn: Rectangle {
    property string glyph: ""
    property bool danger: false
    property bool accent: false
    signal clicked()
    width: 22
    height: 22
    radius: 5
    Layout.alignment: Qt.AlignVCenter
    color: rbMa.containsMouse
           ? (danger ? Qt.rgba(1, 0.42, 0.38, 0.16)
                     : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.10))
           : (accent ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16) : "transparent")
    border.color: danger
                  ? Qt.rgba(1, 0.42, 0.38, rbMa.containsMouse ? 0.85 : 0.35)
                  : (accent ? Color.accent
                            : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b,
                                      rbMa.containsMouse ? 0.55 : 0.22))
    border.width: 1
    Text {
      anchors.centerIn: parent
      text: parent.glyph
      color: parent.danger ? "#ff6b60" : (parent.accent ? Color.accent : Color.popups.text)
      font.family: root.iconFont
      font.pixelSize: 10
    }
    MouseArea {
      id: rbMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.clicked()
    }
  }

  // --- prefs (persisted via helper) ----------------------------------------
  function pref(k, dflt) {
    return root.prefs[k] !== undefined ? root.prefs[k] : dflt
  }
  function setPref(k, v) {
    var p = root.prefs
    p[k] = v
    root.prefs = Object.assign({}, p)  // reassign to trigger bindings
    var s = (typeof v === "string") ? v : (v ? "1" : "0")
    Quickshell.execDetached([root.binPath, "pref", k, s])
  }

  // Fast poll while the popup is open or any app is frozen (veil tracking).
  Timer {
    interval: (root.popupOpen || root.frozenCount > 0) ? 2000 : 15000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  // History poll: while the popup is open OR the bar shows the mini graph.
  Timer {
    interval: 2000
    repeat: true
    running: root.popupOpen || root.barMode === "graph"
    onTriggered: root.refreshHistory()
  }

  // Delayed refresh after an action so cgroup/compositor state settles.
  Timer {
    id: settleTimer
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  Process {
    id: scanProc
    command: [root.binPath, "state"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseState(text)
    }
  }

  Process {
    id: histProc
    command: [root.binPath, "history"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.hist = JSON.parse(text || "{}")
        } catch (e) {}
      }
    }
  }

  Process {
    id: procsProc
    command: [root.binPath, "procs", "0"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var pd = root.procsData
        try {
          pd[root.pendingProcsPid] = JSON.parse(text || "[]")
        } catch (e) {
          pd[root.pendingProcsPid] = []
        }
        root.procsData = Object.assign({}, pd)
        if (root.procsQueue.length > 0) {
          var next = root.procsQueue.shift()
          root.runProcs(next)
        }
      }
    }
  }

  function runProcs(pid) {
    root.pendingProcsPid = pid
    procsProc.command = [root.binPath, "procs", String(pid)]
    procsProc.running = true
  }

  function fetchProcs(pid) {
    if (procsProc.running) {
      if (root.procsQueue.indexOf(pid) < 0) root.procsQueue.push(pid)
      return
    }
    root.runProcs(pid)
  }

  function toggleExpand(pid) {
    var e = root.expandedProcs
    e[pid] = !e[pid]
    root.expandedProcs = Object.assign({}, e)
    if (e[pid]) root.fetchProcs(pid)
  }

  function subRows(pid) {
    if (!root.expandedProcs[pid]) return []
    return root.procsData[pid] || []
  }

  // Latest CPU% of an app from the daemon history (top-style, can exceed
  // 100% on multicore). "" when the daemon has no series for it yet.
  function cpuFor(unit, pid) {
    var key = (unit && unit.length > 0) ? unit : ("pid" + pid)
    var h = root.hist
    if (!h || !h.apps || !h.apps[key] || !h.apps[key].cpu || h.apps[key].cpu.length === 0) return ""
    return Math.round(h.apps[key].cpu[h.apps[key].cpu.length - 1]) + "%"
  }

  // Numeric CPU for sorting (0 when no series yet).
  function cpuVal(unit, pid) {
    var key = (unit && unit.length > 0) ? unit : ("pid" + pid)
    var h = root.hist
    if (!h || !h.apps || !h.apps[key] || !h.apps[key].cpu || h.apps[key].cpu.length === 0) return 0
    return h.apps[key].cpu[h.apps[key].cpu.length - 1]
  }

  // List sort order: "ram" (default) / "cpu" / "name".
  property string sortBy: {
    var s = root.prefs["sortBy"]
    return (s === "cpu" || s === "name") ? s : "ram"
  }
  function cycleSort() {
    setPref("sortBy", sortBy === "ram" ? "cpu" : (sortBy === "cpu" ? "name" : "ram"))
  }

  // Last N samples of an app's RSS series as 0..1 fractions. Normalized
  // against the FULL-series max: a sliding-window max rescales every bar on
  // each poll (the "flicker"), a stable max doesn't.
  function sparkFor(unit, pid, n) {
    var key = (unit && unit.length > 0) ? unit : ("pid" + pid)
    var h = root.hist
    if (!h || !h.apps || !h.apps[key]) return []
    var series = h.apps[key].rss || []
    if (series.length === 0) return []
    var max = 1
    for (var i = 0; i < series.length; i++) if (series[i] > max) max = series[i]
    var out = []
    var start = Math.max(0, series.length - n)
    for (var j = start; j < series.length; j++) out.push(series[j] / max)
    return out
  }

  function parseState(text) {
    try {
      var data = JSON.parse(text)
      var arr = data.apps || []
      var sb = root.sortBy
      arr.sort(function(a, b) {
        if (sb === "name") return a.name.localeCompare(b.name)
        if (sb === "cpu") return cpuVal(b.unit, b.pid) - cpuVal(a.unit, a.pid)
        return b.rss_mb - a.rss_mb
      })
      root.apps = arr
      root.monitors = data.monitors || []
      var n = 0
      var fw = []
      for (var i = 0; i < root.apps.length; i++) {
        var a = root.apps[i]
        if (a.frozen) {
          n++
          var wins = a.wins || []
          for (var j = 0; j < wins.length; j++) {
            var w = wins[j]
            fw.push({
              "addr": w.addr, "x": w.x, "y": w.y, "w": w.w, "h": w.h,
              "ws": w.ws, "mon": w.mon, "pinned": w.pinned,
              "app": a.name, "pid": a.pid
            })
          }
        }
      }
      root.frozenCount = n
      root.frozenWins = fw
      if (data.mem) {
        root.memAvailMb = data.mem.avail_mb || 0
        root.memTotalMb = data.mem.total_mb || 0
        root.psiSome10 = data.mem.psi_some10 || 0.0
        root.swapUsedMb = data.mem.swap_used_mb || 0
      }
      if (data.zswap) {
        root.zswapAvailable = !!data.zswap.available
        root.zswapEnabled = !!data.zswap.enabled
      }
      if (data.pressure) root.pressureCritical = !!data.pressure.critical
      root.background = data.background || []
      root.prefs = data.prefs || {}
      if (data.now) {
        root.cpuNow = data.now.cpu || 0.0
        root.memNow = data.now.mem || 0.0
      }
      // Refresh expanded trees with fresh data.
      root.procsData = {}
      for (var pid in root.expandedProcs) {
        if (root.expandedProcs[pid]) root.fetchProcs(parseInt(pid))
      }

      // Out-of-memory dialog: auto-open while pressure is critical and
      // something is frozen. Reopens after 60s if the user closed nothing.
      if (root.pressureCritical && root.frozenCount > 0
          && (Date.now() - root.dismissedAt) > 60000) {
        root.popupOpen = true
      }
    } catch (e) {
      root.apps = []
      root.frozenWins = []
      root.frozenCount = 0
    }
  }

  function refresh() {
    if (!scanProc.running) scanProc.running = true
  }

  function refreshHistory() {
    if (!histProc.running) histProc.running = true
  }

  function action(verb, pid) {
    Quickshell.execDetached([root.binPath, verb, String(pid)])
    settleTimer.restart()
    // Resume should BRING BACK the app: focus its window once it settles.
    if (verb === "thaw") {
      focusAfterThaw.pid = pid
      focusAfterThaw.restart()
    }
  }

  // Delayed focus so the compositor sees the thawed window first.
  Timer {
    id: focusAfterThaw
    property int pid: 0
    interval: 900
    repeat: false
    onTriggered: if (pid > 0) Quickshell.execDetached([root.binPath, "focus", String(pid)])
  }

  function resumeAll() {
    for (var i = 0; i < root.apps.length; i++) {
      if (root.apps[i].frozen) {
        Quickshell.execDetached([root.binPath, "thaw", String(root.apps[i].pid)])
      }
    }
    settleTimer.restart()
  }

  function monInfo(name) {
    for (var i = 0; i < root.monitors.length; i++) {
      if (root.monitors[i].name === name) return root.monitors[i]
    }
    return null
  }

  function winVisible(win) {
    if (win.pinned) return true
    var m = monInfo(win.mon)
    if (!m) return true
    return win.ws === m.active_ws
  }

  function copyZswapCmd() {
    Quickshell.execDetached([root.binPath, "zswap-copy"])
  }

  function closePopup() {
    root.dismissedAt = Date.now()
    root.popupOpen = false
  }

  // The layer surface configures async: width/height are 0 on the first
  // frames. Center EVENT-DRIVEN from size changes (polling retries lose the
  // race at shell startup under load, parking the card at (0,0) under the bar).
  function maybeCenterCard() {
    if (!root.popupOpen || root.cardPosSet) return
    if (popupWin.width > card.width && popupWin.height > card.height) {
      card.x = Math.max(0, (popupWin.width - card.width) / 2)
      card.y = Math.max(0, (popupWin.height - card.height) / 2)
      root.cardPosSet = true
    }
  }

  function centerCard() {
    root.maybeCenterCard()
  }

  onPopupOpenChanged: {
    if (root.popupOpen && !root.cardPosSet) root.centerCard()
    if (root.popupOpen) {
      root.refreshHistory()
      root.readKeybind()
      root.selIdx = (root.apps.length + root.background.length) ? 0 : -1
      Qt.callLater(function() { if (root.popupOpen) card.forceActiveFocus() })
    }
  }

  // --- keyboard navigation (Omarchy style: arrows + single-key actions) ----
  property int selIdx: -1

  function ensureSelVisible() {
    if (root.selIdx < 0) return
    var it = null, y = 0
    if (root.selIdx < root.apps.length) {
      it = appsRep.itemAt(root.selIdx)
      if (!it) return
      y = it.y
    } else {
      it = bgRep.itemAt(root.selIdx - root.apps.length)
      if (!it) return
      y = bgRep.y + it.y
    }
    var h = it.height
    if (listFlick.contentY > y) listFlick.contentY = y
    else if (listFlick.contentY + listFlick.height < y + h)
      listFlick.contentY = y + h - listFlick.height
  }

  function handleCardKey(ev) {
    if (ev.key === Qt.Key_Escape) { root.closePopup(); ev.accepted = true; return }
    if (ev.key === Qt.Key_R) { root.refresh(); ev.accepted = true; return }
    if (ev.key === Qt.Key_G) { root.setPref("showGraphs", !root.pref("showGraphs", true)); ev.accepted = true; return }
    if (ev.key === Qt.Key_D) { root.setPref("graphDetail", !root.pref("graphDetail", false)); ev.accepted = true; return }
    if (ev.key === Qt.Key_B) { root.cycleBarMode(); ev.accepted = true; return }
    var na = root.apps.length
    var n = na + root.background.length
    if (n === 0) return
    if (ev.key === Qt.Key_Down) {
      root.selIdx = Math.min(root.selIdx + 1, n - 1)
      root.ensureSelVisible()
      ev.accepted = true
      return
    }
    if (ev.key === Qt.Key_Up) {
      root.selIdx = Math.max(root.selIdx - 1, 0)
      root.ensureSelVisible()
      ev.accepted = true
      return
    }
    if (root.selIdx < 0 || root.selIdx >= n) return
    // Background rows: pause/kill only (no window to focus, no tree).
    if (root.selIdx >= na) {
      var bg = root.background[root.selIdx - na]
      if (ev.key === Qt.Key_Space || ev.key === Qt.Key_P) {
        root.action(bg.frozen ? "thaw" : "freeze", bg.pid)
        ev.accepted = true
      } else if (ev.key === Qt.Key_X || ev.key === Qt.Key_Delete) {
        root.action("kill", bg.pid)
        ev.accepted = true
      }
      return
    }
    var app = root.apps[root.selIdx]
    if (ev.key === Qt.Key_Right && app.procs > 1 && !root.expandedProcs[app.pid]) {
      root.toggleExpand(app.pid); ev.accepted = true
    } else if (ev.key === Qt.Key_Left && root.expandedProcs[app.pid]) {
      root.toggleExpand(app.pid); ev.accepted = true
    } else if (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) {
      Quickshell.execDetached([root.binPath, "focus", String(app.pid)])
      ev.accepted = true
    } else if (ev.key === Qt.Key_Space || ev.key === Qt.Key_P) {
      root.action(app.frozen ? "thaw" : "freeze", app.pid)
      ev.accepted = true
    } else if (ev.key === Qt.Key_X || ev.key === Qt.Key_Delete) {
      root.action("kill", app.pid)
      ev.accepted = true
    }
  }

  // Shell panel-widget protocol: `omarchy-shell shell toggle <plugin-id>`
  // finds the live bar instance and drives it via open()/close()/opened.
  readonly property bool opened: root.popupOpen
  function open() { root.popupOpen = true }
  function close() { root.closePopup() }

  // Global IPC: direct `qs ipc call omarchy.task-manager toggle` also works
  // (the keybind uses the shell dispatch above).
  IpcHandler {
    target: "omarchy.task-manager"
    function open(): void { root.popupOpen = true }
    function show(): void { root.popupOpen = true }
    function close(): void { root.closePopup() }
    function hide(): void { root.closePopup() }
    function toggle(): void { if (root.popupOpen) root.closePopup(); else root.popupOpen = true }
  }

  // --- SUPER+SHIFT+T keybind (OPT-IN; marketplace-safe) --------------------
  // The helper writes/removes the hyprland lua ONLY on explicit user action
  // (this card's keyboard toggle). install.sh never enables it.
  property string kbScript: root.binPath.replace("task-manager-launch.sh", "task-manager-keybind.sh")
  property bool keybindOn: false

  Process {
    id: kbProc
    command: [root.kbScript, "status"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.keybindOn = (text || "").trim() === "enabled"
    }
  }
  Timer {
    id: kbRecheck
    interval: 1500
    repeat: false
    onTriggered: root.readKeybind()
  }
  function readKeybind() { if (!kbProc.running) kbProc.running = true }
  function toggleKeybind() {
    root.keybindOn = !root.keybindOn  // optimistic; re-checked after write
    Quickshell.execDetached([root.kbScript, "toggle"])
    kbRecheck.restart()
  }

  // --- ONE persistent veil surface per screen, created at shell start. ---
  // Layer surfaces stack by creation order within a layer: because this
  // surface exists from boot, panels opened LATER (X-Panel, etc.) render
  // ABOVE it, while app windows (always below the Top layer) stay below.
  // mask: empty Region = click-through (the pill opens the manager).
  Variants {
    model: Quickshell.screens
    PanelWindow {
      id: veilSurface
      required property var modelData
      property var scr: modelData
      screen: scr
      visible: true
      anchors { top: true; left: true; right: true; bottom: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}
      WlrLayershell.namespace: "tm-overlay"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Repeater {
        model: root.frozenWins
        delegate: Rectangle {
          required property var modelData
          property var win: modelData
          visible: win.mon === veilSurface.scr.name && root.winVisible(win)
          x: win.x - (veilSurface.scr ? veilSurface.scr.x : 0)
          y: win.y - (veilSurface.scr ? veilSurface.scr.y : 0)
          width: Math.max(win.w, 1)
          height: Math.max(win.h, 1)
          color: Qt.rgba(0.42, 0.44, 0.48, 0.55)
          radius: Style.cornerRadius
          border.color: Qt.rgba(1, 1, 1, 0.28)
          border.width: 1

          Column {
            anchors.centerIn: parent
            spacing: Style.space(4)
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "\uDB80\uDFE4"
              color: "#ffffff"
              font.family: root.iconFont
              font.pixelSize: Style.font.title * 1.6
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.tr("pausedTag")
              color: "#ffffff"
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: win.app
              color: Qt.rgba(1, 1, 1, 0.75)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // --- popup: Overlay layer, above everything, visible on all workspaces ---
  PanelWindow {
    id: popupWin
    visible: root.popupOpen
    screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    anchors { top: true; left: true; right: true; bottom: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    // Pinned: input region shrinks to the card — clicks outside pass through
    // to the windows below. Unpinned: full-screen area catches outside
    // clicks to close the popup.
    mask: root.pinned ? cardInputRegion : null
    WlrLayershell.namespace: "tm-popup"
    WlrLayershell.layer: WlrLayer.Overlay
    // Keyboard: unpinned popup grabs input (arrows/shortcuts work the moment
    // it opens, Esc closes). Pinned must never steal keys from real windows.
    WlrLayershell.keyboardFocus: root.pinned ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive
    onWidthChanged: root.maybeCenterCard()
    onHeightChanged: root.maybeCenterCard()

    Region { id: cardInputRegion; item: card }

    // Click outside the card closes the popup (unless pinned).
    MouseArea {
      anchors.fill: parent
      onClicked: if (!root.pinned) root.closePopup()
    }

    Rectangle {
      id: card
      width: root.cardW
      height: root.cardH
      // Positioned by root.centerCard() on first open; DragHandler moves it.
      color: Color.popups.background
      border.color: Color.popups.border
      border.width: 1
      radius: Style.cornerRadius

      // Keyboard navigation focus target (see root.handleCardKey).
      focus: root.popupOpen
      Keys.onPressed: function(ev) { root.handleCardKey(ev) }

      // Interceptor: swallows clicks on card padding so the full-screen
      // close area behind the card does not fire.
      MouseArea { anchors.fill: parent }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(12)
        spacing: Style.space(8)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          // Drag zone (left): grab the header to move the card.
          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: hdrTitle.implicitHeight + Style.space(8)
            DragHandler {
              target: card
              grabPermissions: PointerHandler.TakeOverForbidden
              onActiveChanged: if (active) root.cardPosSet = true
            }
            Row {
              spacing: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              Text {
                text: "\u28BF"  // ⠿ drag handle
                color: Qt.darker(Color.popups.text, 1.8)
                font.family: root.iconFont
                font.pixelSize: Style.font.subtitle
              }
              Text {
                id: hdrTitle
                text: root.tr("title")
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }
          }
          // Pin: keep the dialog visible (outside clicks don't close it).
          IconBtn {
            glyph: "\uF08D"
            active: root.pinned
            onClicked: root.pinned = !root.pinned
          }
          // Eye: cycle the bar pill display — icon only → numbers →
          // numbers + mini CPU graph → icon only.
          IconBtn {
            glyph: root.barMode === "graph" ? "\uF201"
                 : (root.barMode === "off" ? "\uDB81\uDED1" : "\uDB81\uDED0")
            active: root.barMode !== "off"
            onClicked: root.cycleBarMode()
          }
          // Chart: per-row sparklines (bar chart icon).
          IconBtn {
            glyph: "\uF080"
            active: root.pref("sparklines", false)
            onClicked: root.setPref("sparklines", !root.pref("sparklines", false))
          }
          // Sort: cycle RAM → CPU → name (bars + arrow reads as "sort").
          IconBtn {
            glyph: "\uF161"
            active: root.sortBy !== "ram"
            onClicked: root.cycleSort()
          }
          IconBtn { glyph: "\uDB81\uDC53"; active: false; onClicked: root.refresh() }
          // Keyboard: OPT-IN SUPER+SHIFT+T bind — writes the hyprland lua
          // only on this explicit click (marketplace rule: consent required).
          IconBtn {
            glyph: "\uDB80\uDF0C"
            active: root.keybindOn
            onClicked: root.toggleKeybind()
          }
          IconBtn { glyph: "\uDB80\uDD56"; active: false; onClicked: root.closePopup() }
        }

        Text {
          Layout.fillWidth: true
          text: root.tr("ramFree") + ": " + (root.memAvailMb / 1024).toFixed(1) + " GB / "
                + (root.memTotalMb / 1024).toFixed(0) + " GB   ·   PSI "
                + root.psiSome10.toFixed(2) + "   ·   " + root.tr("paused") + ": " + root.frozenCount
                + (root.swapUsedMb > 50 ? "   ·   SWAP " + (root.swapUsedMb / 1024).toFixed(1) + " GB" : "")
          color: Qt.darker(Color.popups.text, 1.3)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          Layout.fillWidth: true
          height: 1
          color: Color.popups.border
        }

        // zswap warning banner: compression off = squeezed RAM goes to disk.
        Rectangle {
          id: zswapBanner
          visible: !root.zswapEnabled
          Layout.fillWidth: true
          height: bannerCol.implicitHeight + Style.space(16)
          color: Qt.rgba(0.95, 0.65, 0.15, 0.12)
          border.color: Qt.rgba(0.95, 0.65, 0.15, 0.5)
          border.width: 1
          radius: Style.cornerRadius - 2

          Column {
            id: bannerCol
            width: parent.width - Style.space(16)
            anchors.centerIn: parent
            spacing: Style.space(4)

            Text {
              width: parent.width
              text: root.zswapAvailable ? root.tr("zswapWarn") : root.tr("zswapNoKernel")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Text {
              width: parent.width
              visible: root.zswapAvailable
              text: "sudo sh -c 'echo Y > /sys/module/zswap/parameters/enabled'"
              color: Color.accent
              font.family: root.iconFont
              font.pixelSize: Style.font.caption
              wrapMode: Text.WrapAnywhere
            }
            Text {
              width: parent.width
              visible: root.zswapAvailable
              text: root.tr("zswapPersist")
              color: Qt.darker(Color.popups.text, 1.5)
              font.family: root.iconFont
              font.pixelSize: Style.font.caption - 1
              wrapMode: Text.WrapAnywhere
            }
            Button {
              visible: root.zswapAvailable
              iconText: root.tr("copyCmd")
              bordered: true
              onClicked: root.copyZswapCmd()
            }
          }
        }

        // The list FLEXES: it absorbs leftover card space, so the Activity
        // section and footer pin to the bottom with no dead space.
        Flickable {
          id: listFlick
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true

          Column {
            id: listColumn
            width: parent.width
            spacing: Style.space(6)

            Text {
              visible: root.apps.length === 0
              text: root.tr("noApps")
              color: Qt.darker(Color.popups.text, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Repeater {
              id: appsRep
              model: root.apps
              Column {
                required property var modelData
                required property int index
                property var app: modelData
                width: listColumn.width
                spacing: 0

                Rectangle {
                  width: parent.width
                  height: row.implicitHeight + Style.space(12)
                  // Keyboard selection highlight (only when the keyboard owns
                  // the popup — pinned cards take no keys).
                  color: (index === root.selIdx && !root.pinned)
                         ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
                         : app.frozen
                           ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
                           : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.03)
                  radius: Style.cornerRadius - 2

                  RowLayout {
                    id: row
                    width: parent.width - Style.space(16)
                    anchors.centerIn: parent
                    spacing: Style.space(8)

                    // Tree expander slot: FIXED WIDTH even when the app has
                    // no subprocesses, so every name starts at the same x.
                    Item {
                      width: 14
                      height: 14
                      Layout.alignment: Qt.AlignVCenter
                      Text {
                        anchors.centerIn: parent
                        visible: app.procs > 1
                        text: root.expandedProcs[app.pid] ? "\uDB80\uDD40" : "\uDB80\uDD42"
                        color: Qt.darker(Color.popups.text, 1.5)
                        font.family: root.iconFont
                        font.pixelSize: Style.font.caption
                      }
                      MouseArea {
                        anchors.fill: parent
                        enabled: app.procs > 1
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleExpand(app.pid)
                      }
                    }

                    // Click the app name/title to focus its window.
                    MouseArea {
                      Layout.fillWidth: true
                      Layout.preferredHeight: nameCol.implicitHeight
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.action("focus", app.pid)

                      Column {
                        id: nameCol
                        width: parent.width
                        spacing: Style.space(2)
                        property string cpuPct: root.cpuFor(app.unit, app.pid)

                        Text {
                          width: parent.width
                          text: app.name + (nameCol.cpuPct !== "" ? "  ·  " + nameCol.cpuPct : "")
                                + (app.frozen ? "  ·  " + root.tr("pausedTag") : "")
                          color: app.frozen ? Qt.darker(Color.popups.text, 1.6) : Color.popups.text
                          font.family: Style.font.family
                          font.pixelSize: Style.font.body
                          font.bold: true
                          elide: Text.ElideRight
                        }
                        Text {
                          width: parent.width
                          text: app.title + "  ·  " + app.rss_mb + " MB"
                                + (app.windows > 1 ? "  ·  " + app.windows + " " + root.tr("windows") : "")
                                + (app.procs > 1 ? "  ·  " + app.procs + " " + root.tr("procs") : "")
                          color: Qt.darker(Color.popups.text, 1.4)
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                      }
                    }

                    // Per-row sparkline (RSS history from the watchdog).
                    // Canvas: one atomic repaint per update — a Repeater of
                    // per-bar delegates flickers as they are recreated.
                    Canvas {
                      id: sparkCanvas
                      width: 50
                      height: 14
                      visible: root.pref("sparklines", false)
                      Layout.alignment: Qt.AlignVCenter
                      property var sd: root.sparkFor(app.unit, app.pid, 24)
                      onSdChanged: requestPaint()
                      onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        if (!sd || sd.length === 0) return
                        var bw = width / sd.length
                        ctx.fillStyle = app.frozen ? Qt.darker(Color.accent, 1.6) : Color.accent
                        for (var i = 0; i < sd.length; i++) {
                          var bh = Math.max(1, sd[i] * height)
                          ctx.fillRect(i * bw, height - bh, Math.max(1, bw - 1), bh)
                        }
                      }
                    }

                    RowBtn {
                      glyph: app.frozen ? "\uDB81\uDC0A" : "\uDB80\uDFE4"
                      accent: app.frozen
                      onClicked: root.action(app.frozen ? "thaw" : "freeze", app.pid)
                    }
                    RowBtn {
                      glyph: "\uDB80\uDD56"
                      danger: true
                      onClicked: root.action("kill", app.pid)
                    }
                  }
                }

                // Expanded subprocess rows (tree view).
                Repeater {
                  model: root.subRows(app.pid)
                  Rectangle {
                    required property var modelData
                    property var proc: modelData
                    width: parent.width - Style.space(20)
                    x: Style.space(20)
                    height: subRow.implicitHeight + Style.space(4)
                    color: "transparent"

                    RowLayout {
                      id: subRow
                      width: parent.width - Style.space(8)
                      anchors.centerIn: parent
                      spacing: Style.space(8)

                      Text {
                        Layout.fillWidth: true
                        text: "└ " + proc.comm
                        color: Qt.darker(Color.popups.text, 1.3)
                        font.family: root.iconFont
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                      Text {
                        text: proc.state
                        color: proc.state === "T" ? Color.accent
                               : (proc.state === "Z" ? "#ff3b30"
                               : Qt.darker(Color.popups.text, 1.6))
                        font.family: root.iconFont
                        font.pixelSize: Style.font.caption
                        font.bold: proc.state === "T" || proc.state === "Z"
                      }
                      Text {
                        text: proc.rss_mb + " MB"
                        color: Qt.darker(Color.popups.text, 1.5)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }
            }

            // --- background processes (no window), grouped by comm ---
            Text {
              visible: root.background.length > 0
              text: root.tr("background")
              color: Qt.darker(Color.popups.text, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Repeater {
              id: bgRep
              model: root.background
              Rectangle {
                required property var modelData
                required property int index
                property var bg: modelData
                width: listColumn.width
                height: bgRow.implicitHeight + Style.space(8)
                color: ((root.apps.length + index) === root.selIdx && !root.pinned)
                       ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
                       : bg.frozen
                         ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
                         : "transparent"
                radius: Style.cornerRadius - 2

                RowLayout {
                  id: bgRow
                  width: parent.width - Style.space(16)
                  anchors.centerIn: parent
                  spacing: Style.space(8)

                  // Fixed slot matching the windowed rows' expander column.
                  Item { width: 14; height: 1 }

                  Text {
                    Layout.fillWidth: true
                    property string cpuPct: root.cpuFor(bg.unit, bg.pid)
                    text: bg.name + (cpuPct !== "" ? "  ·  " + cpuPct : "")
                          + (bg.frozen ? "  ·  " + root.tr("pausedTag") : "")
                    color: bg.frozen ? Qt.darker(Color.popups.text, 1.6) : Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  Text {
                    text: (bg.procs > 1 ? bg.procs + " " + root.tr("procs") + " · " : "")
                          + bg.rss_mb + " MB"
                    color: Qt.darker(Color.popups.text, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  // Pause (scope or signal fallback) + kill, on every row.
                  RowBtn {
                    glyph: bg.frozen ? "\uDB81\uDC0A" : "\uDB80\uDFE4"
                    accent: bg.frozen
                    onClicked: root.action(bg.frozen ? "thaw" : "freeze", bg.pid)
                  }
                  RowBtn {
                    glyph: "\uDB80\uDD56"
                    danger: true
                    onClicked: root.action("kill", bg.pid)
                  }
                }
              }
            }
          }
        }

        // --- activity section: historical CPU/RAM (collapsible) ------------
        Column {
          id: activitySection
          Layout.fillWidth: true
          spacing: Style.space(4)
          visible: root.pref("showGraphs", true)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Text {
              text: root.tr("activity") + "   ·   CPU " + root.cpuNow.toFixed(0)
                    + "%   ·   RAM " + root.memNow.toFixed(0) + "%"
              color: Qt.darker(Color.popups.text, 1.3)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Item { Layout.fillWidth: true; height: 1 }
            // Detail: include per-core CPU lines (chip = cores).
            IconBtn {
              glyph: "\uDB83\uDEE0"
              active: root.pref("graphDetail", false)
              onClicked: root.setPref("graphDetail", !root.pref("graphDetail", false))
            }
            Button {
              iconText: "\u25BE"  // collapse (down = expanded, like the tree rows)
              bordered: false
              onClicked: root.setPref("showGraphs", false)
            }
          }

          Canvas {
            id: graphCanvas
            width: parent.width
            height: 96
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var w = width, h = height
              var hst = root.hist
              ctx.strokeStyle = Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.15)
              ctx.lineWidth = 1
              for (var g = 1; g < 4; g++) {
                ctx.beginPath()
                ctx.moveTo(0, h * g / 4)
                ctx.lineTo(w, h * g / 4)
                ctx.stroke()
              }
              var series = (hst && hst.cpu) ? hst.cpu : []
              if (series.length < 2) return
              var n = series.length
              var xstep = w / (n - 1)
              var mems = hst.mem || []
              ctx.strokeStyle = Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.55)
              ctx.lineWidth = 1.5
              ctx.beginPath()
              for (var m = 0; m < Math.min(mems.length, n); m++) {
                var ym = h - Math.min(100, mems[m]) / 100 * h
                if (m === 0) ctx.moveTo(m * xstep, ym)
                else ctx.lineTo(m * xstep, ym)
              }
              ctx.stroke()
              ctx.strokeStyle = Color.accent
              ctx.lineWidth = 2
              ctx.beginPath()
              for (var k = 0; k < n; k++) {
                var yk = h - Math.min(100, series[k]) / 100 * h
                if (k === 0) ctx.moveTo(k * xstep, yk)
                else ctx.lineTo(k * xstep, yk)
              }
              ctx.stroke()
            }
            Connections {
              target: root
              function onHistChanged() { graphCanvas.requestPaint() }
            }
            Component.onCompleted: requestPaint()
          }

          // Per-core detail: its OWN mini-graph with its own 0-100% scale,
          // below the main one. Alternating tints separate adjacent cores.
          Canvas {
            id: coresCanvas
            width: parent.width
            height: 52
            visible: root.pref("graphDetail", false)
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var w = width, h = height
              var hst = root.hist
              if (!hst || !hst.cores || hst.cores.length < 2) return
              var n = hst.cores.length
              var last = hst.cores[n - 1]
              if (!last) return
              var ncores = last.length
              var xstep = w / (n - 1)
              ctx.strokeStyle = Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.10)
              ctx.lineWidth = 1
              ctx.beginPath()
              ctx.moveTo(0, h / 2)
              ctx.lineTo(w, h / 2)
              ctx.stroke()
              for (var c = 0; c < ncores; c++) {
                ctx.strokeStyle = (c % 2 === 0)
                  ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)
                  : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.35)
                ctx.lineWidth = 1
                ctx.beginPath()
                for (var i = 0; i < n; i++) {
                  var v = Math.min(100, (hst.cores[i] && hst.cores[i][c]) || 0)
                  var y = h - 1 - v / 100 * (h - 2)
                  if (i === 0) ctx.moveTo(i * xstep, y)
                  else ctx.lineTo(i * xstep, y)
                }
                ctx.stroke()
              }
            }
            Connections {
              target: root
              function onHistChanged() { coresCanvas.requestPaint() }
            }
            Component.onCompleted: requestPaint()
          }
          Text {
            visible: root.pref("graphDetail", false)
            text: root.tr("cores")
            color: Qt.darker(Color.popups.text, 1.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption - 1
          }
        }

        // Collapsed activity stub (re-open).
        Button {
          visible: !root.pref("showGraphs", true)
          iconText: "▴  " + root.tr("activity")
          bordered: false
          anchors.horizontalCenter: parent.horizontalCenter
          onClicked: root.setPref("showGraphs", true)
        }

        Row {
          visible: root.frozenCount > 0
          Layout.alignment: Qt.AlignHCenter
          spacing: Style.space(8)
          Button {
            iconText: "▶▶  " + root.tr("resumeAll")
            bordered: true
            onClicked: root.resumeAll()
          }
          // Continuar: keep them paused, dismiss the dialog (reopens in 60s
          // if pressure is still critical and nothing was closed).
          Button {
            iconText: root.tr("continueBtn")
            bordered: true
            onClicked: root.closePopup()
          }
        }

        // Keyboard shortcut legend — always pinned to the card bottom so
        // users discover the navigation keys.
        Text {
          Layout.fillWidth: true
          text: root.tr("keysHint")
          color: Qt.darker(Color.popups.text, 1.7)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption - 1
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }

      // Resize grip (bottom-right corner, ABOVE the content in z-order).
      // Drag to resize; geometry persists via cardW/cardH prefs.
      Item {
        width: 20
        height: 20
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 2
        Text {
          anchors.centerIn: parent
          text: "◢"
          color: resizeMa.containsMouse ? Color.popups.text : Qt.darker(Color.popups.text, 1.8)
          font.pixelSize: 11
        }
        MouseArea {
          id: resizeMa
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          cursorShape: Qt.SizeFDiagCursor
        }
        DragHandler {
          target: null
          property real startW: 0
          property real startH: 0
          onActiveChanged: {
            if (active) {
              startW = root.cardW
              startH = root.cardH
            } else {
              // Keep the card on screen, then persist.
              if (card.x + card.width > popupWin.width - 4) card.x = Math.max(4, popupWin.width - card.width - 4)
              if (card.y + card.height > popupWin.height - 4) card.y = Math.max(4, popupWin.height - card.height - 4)
              root.setPref("cardW", String(root.cardW))
              root.setPref("cardH", String(root.cardH))
            }
          }
          onTranslationChanged: {
            if (!active) return
            root.cardW = Math.round(Math.max(440, Math.min(popupWin.width - 40, startW + translation.x)))
            root.cardH = Math.round(Math.max(360, Math.min(popupWin.height - 40, startH + translation.y)))
          }
        }
      }
    }
  }

  // --- bar pill ---
  Item {
    anchors.fill: parent

    // Centered inside the FIXED-width slot: the slot never resizes, so the
    // cluster is stable across modes and never pushes bar neighbors.
    // (anchors.right broke rendering: the bar slot sizes from implicitWidth
    // and the row collapsed off-slot.)
    Row {
      anchors.centerIn: parent
      spacing: 4
      Text {
        text: "\uF0AE"
        color: root.frozenCount > 0 ? Color.accent : Color.foreground
        font.family: root.iconFont
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
      // CPU: microchip + fixed-width % + its OWN sparkline (graph mode).
      Text {
        visible: root.barMode !== "off"
        text: "\uF2DB " + ("   " + root.cpuNow.toFixed(0)).slice(-3) + "%"
        color: Qt.darker(Color.foreground, 1.3)
        font.family: root.iconFont
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
      Canvas {
        visible: root.barMode === "graph"
        width: 30
        height: 12
        anchors.verticalCenter: parent.verticalCenter
        property var series: (root.hist && root.hist.cpu) ? root.hist.cpu : []
        onSeriesChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var n = series.length
          if (n < 2) return
          var start = Math.max(0, n - 12)
          var count = n - start
          var max = 20
          for (var s = start; s < n; s++) if (series[s] > max) max = series[s]
          max *= 1.15
          var step = width / 11
          ctx.strokeStyle = Color.accent
          ctx.lineWidth = 1.5
          ctx.beginPath()
          for (var i = 0; i < count; i++) {
            var v = Math.min(max, series[start + i]) / max
            var y = height - 1 - v * (height - 2)
            if (i === 0) ctx.moveTo(1, y)
            else ctx.lineTo(1 + i * step, y)
          }
          ctx.stroke()
        }
      }
      // RAM: DIMM stick + fixed-width % + its OWN sparkline (graph mode).
      Text {
        visible: root.barMode !== "off"
        text: "\uDB81\uDD38 " + ("   " + root.memNow.toFixed(0)).slice(-3) + "%"
        color: Qt.darker(Color.foreground, 1.3)
        font.family: root.iconFont
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
      Canvas {
        visible: root.barMode === "graph"
        width: 30
        height: 12
        anchors.verticalCenter: parent.verticalCenter
        property var series: (root.hist && root.hist.mem) ? root.hist.mem : []
        onSeriesChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var n = series.length
          if (n < 2) return
          var start = Math.max(0, n - 12)
          var count = n - start
          var max = 20
          for (var s = start; s < n; s++) if (series[s] > max) max = series[s]
          max *= 1.15
          var step = width / 11
          ctx.strokeStyle = Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.8)
          ctx.lineWidth = 1.5
          ctx.beginPath()
          for (var i = 0; i < count; i++) {
            var v = Math.min(max, series[start + i]) / max
            var y = height - 1 - v * (height - 2)
            if (i === 0) ctx.moveTo(1, y)
            else ctx.lineTo(1 + i * step, y)
          }
          ctx.stroke()
        }
      }
    }

    Rectangle {
      visible: root.frozenCount > 0
      anchors.right: parent.right
      anchors.top: parent.top
      width: 14; height: 14; radius: 7
      color: "#ff3b30"
      Text {
        anchors.centerIn: parent
        text: root.frozenCount > 9 ? "9+" : String(root.frozenCount)
        color: "#ffffff"
        font.family: Style.font.family
        font.pixelSize: 8
        font.bold: true
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onClicked: function(mouse) {
      if (mouse.button === Qt.LeftButton) {
        root.popupOpen = !root.popupOpen
        if (root.popupOpen) root.refresh()
      }
    }
  }

  Component.onCompleted: root.refresh()
}
