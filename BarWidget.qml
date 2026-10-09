// Omarchy Task Manager: freeze/resume memory-hogging apps.
// - Pill: tasks glyph + red badge (or live CPU/MEM stats, eye toggle).
// - Popup: draggable Overlay-layer card above all windows, all workspaces.
// - Frozen apps get a grey veil exactly over their windows.
// - Process tree per app, per-row sparklines, historical CPU/RAM graph.
import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "io.github.avillagran.omarchy-task-manager"

  property var apps: []
  // Foreign (system) daemons: informational section, no actions.
  property var system: []

  // The row list renders from a ListModel reconciled in place: assigning a
  // fresh array to a Repeater destroys and recreates every delegate on each
  // poll (the visible "jumps"). set()/move() keep delegates alive — CPU%
  // text and sparklines update without any re-layout flash.
  ListModel { id: appsModel }

  function reconcileApps(arr) {
    var i, j, k
    for (i = appsModel.count - 1; i >= 0; i--) {
      var pid = appsModel.get(i).pid
      var found = false
      for (k = 0; k < arr.length; k++) if (arr[k].pid === pid) { found = true; break }
      if (!found) appsModel.remove(i)
    }
    for (j = 0; j < arr.length; j++) {
      var a = arr[j]
      var idx = -1
      for (i = 0; i < appsModel.count; i++) if (appsModel.get(i).pid === a.pid) { idx = i; break }
      var roles = {
        "pid": a.pid, "name": a.name, "title": a.title || "",
        "rss_mb": a.rss_mb, "frozen": !!a.frozen, "procs": a.procs || 1,
        "windows": a.windows || 0, "unit": a.unit || ""
      }
      if (idx === -1) appsModel.append(roles)
      else {
        // Diff-first: ListModel.set() emits dataChanged even for identical
        // values, which repaints rows and can shift heights (wintitles).
        var cur = appsModel.get(idx)
        var diff = {}
        var changed = false
        for (var key in roles) {
          if (cur[key] !== roles[key]) { diff[key] = roles[key]; changed = true }
        }
        if (changed) appsModel.set(idx, diff)
      }
    }
    // Order to match arr via move() (delegate reuse, no rebuild flash).
    for (i = 0; i < arr.length && i < appsModel.count; i++) {
      if (appsModel.get(i).pid !== arr[i].pid) {
        for (j = i + 1; j < appsModel.count; j++) {
          if (appsModel.get(j).pid === arr[i].pid) { appsModel.move(j, i, 1); break }
        }
      }
    }
  }
  property var frozenWins: []
  property var monitors: []
  property int frozenCount: 0
  property int memAvailMb: 0
  property int memTotalMb: 0
  property real psiSome10: 0.0
  property int swapUsedMb: 0
  property bool zswapAvailable: true
  property bool zswapEnabled: true
  property bool zramBacked: false
  property var background: []
  property bool pressureCritical: false
  property real dismissedAt: 0
  property bool cardPosSet: false
  property string cardPosScreen: ""
  // Popup visibility is SHARED across instances through a runtime file.
  // The shell preloads a ghost BarWidget instance and its IpcHandler/open()
  // calls can land on the ghost (whose popup would be invisible); the file
  // is the single source of truth and only the veil-owner renders the card.
  property bool popupOpen: false
  readonly property string popupStatePath: Quickshell.env("XDG_RUNTIME_DIR") + "/tm-popup-open"
  function writePopupState(opened) {
    Quickshell.execDetached(["sh", "-c", "echo " + (opened ? "1" : "0") + " > \"" + root.popupStatePath + "\""])
  }
  FileView {
    id: popupStateFile
    path: root.popupStatePath
    watchChanges: true
    onFileChanged: this.reload()
    onLoaded: root.popupOpen = (this.text() || "").trim() === "1"
    onLoadFailed: root.popupOpen = false
  }
  property bool pinned: false
  property var prefs: ({})
  property var hist: ({})
  property real cpuNow: 0.0
  property real memNow: 0.0
  property var expandedProcs: ({})
  property var procsRaw: ({})
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
  // Font Awesome glyphs (F0AE/F2DB/F1B3/F013/F161...) live in FiraCode NF,
  // not JetBrainsMono — the bar pill icons use it directly, no fallback.
  property string faFont: "FiraCode Nerd Font"

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
    var s = (typeof v === "string") ? v : (typeof v === "number") ? String(v) : (v ? "1" : "0")
    Quickshell.execDetached([root.binPath, "pref", k, s])
  }

  // Fast poll while the popup is open or any app is frozen (veil tracking).
  Timer {
    // Slow cadence is 3s (state scan costs ~30ms): the watchdog's
    // auto-freeze must surface as a veil almost immediately, not up to
    // 15s later.
    interval: (root.popupOpen || root.frozenCount > 0) ? 2000 : 3000
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
        // Only touch the model when the data actually changed: assigning a
        // fresh array on every fetch rebuilds every expanded row, which
        // redraws the list and resets the scroll position.
        var pid = root.pendingProcsPid
        var raw = (text || "[]").trim()
        if (raw !== (root.procsRaw[pid] || "")) {
          var pr = root.procsRaw
          pr[pid] = raw
          root.procsRaw = pr
          var pd = root.procsData
          try {
            pd[pid] = JSON.parse(raw)
          } catch (e) {
            pd[pid] = []
          }
          root.procsData = Object.assign({}, pd)
        }
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
      root.apps = arr          // logic/keyboard source (sorted)
      root.reconcileApps(arr)  // view model: delegates update IN PLACE
      root.system = data.system || []
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
        root.zramBacked = !!data.zswap.zram
      }
      if (data.pressure) root.pressureCritical = !!data.pressure.critical
      root.background = data.background || []
      root.prefs = data.prefs || {}
      if (data.now) {
        root.cpuNow = data.now.cpu || 0.0
        root.memNow = data.now.mem || 0.0
      }
      // Refresh expanded trees with fresh data (unchanged payloads are
      // dropped inside procsProc, so this does not churn the UI).
      for (var pid in root.expandedProcs) {
        if (root.expandedProcs[pid]) root.fetchProcs(parseInt(pid))
      }

      // Out-of-memory dialog: auto-open while pressure is critical and
      // something is frozen. Reopens after 60s if the user closed nothing.
      if (root.pressureCritical && root.frozenCount > 0
          && (Date.now() - root.dismissedAt) > 60000) {
        root.writePopupState(true)
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
    // Thaw does NOT steal focus: the user clicks the window (or the row's
    // name) when THEY want it focused.
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
    // Live workspace tracking: Quickshell.Hyprland updates on the SAME
    // ipc event as the compositor, so the veil sticks to its workspace
    // instantly instead of waiting for the next state poll.
    var ms = Hyprland.monitors.values
    for (var i = 0; i < ms.length; i++) {
      if (ms[i].name === win.mon)
        return ms[i].activeWorkspace && ms[i].activeWorkspace.id === win.ws
    }
    var m = monInfo(win.mon)
    if (!m) return true
    return win.ws === m.active_ws
  }

  function copyZswapCmd() {
    Quickshell.execDetached([root.binPath, "zswap-copy"])
  }

  function closePopup() {
    root.dismissedAt = Date.now()
    root.writePopupState(false)
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
    if (root.popupOpen) {
      // Resolve the cursor's monitor fresh on every open.
      if (!cursorScreenProc.running) cursorScreenProc.running = true
      // No ownership yet? Re-probe: a stale token (dead owner instance) is
      // claimable now, so the popup can actually render.
      if (!root.veilOwner && !veilClaim.running) veilClaim.running = true
      if (!root.cardPosSet) root.centerCard()
      root.refreshHistory()
      root.readKeybind()
      root.selIdx = (root.apps.length + root.background.length) ? 0 : -1
      Qt.callLater(function() { if (root.popupOpen) card.forceActiveFocus() })
    } else {
      root.cursorValid = false
    }
  }

  // --- keyboard navigation (Omarchy style: arrows + single-key actions) ----
  property int selIdx: -1
  // Gear panel: shortcut, watchdog thresholds, display toggles.
  property bool prefsOpen: false

  // Cursor in popup-window coordinates, for the mascot's subtle look-at.
  // Fed by the popup's full-screen hover area and the card interceptor.
  property real cursorX: 0
  property real cursorY: 0
  property bool cursorValid: false

  function ensureSelVisible() {
    if (root.selIdx < 0) return
    if (root.selIdx < root.apps.length) {
      // ListView scrolls a delegate into view natively.
      listFlick.positionViewAtIndex(root.selIdx, ListView.Contain)
      return
    }
    // Background rows live in the ListView footer (its delegate scope hides
    // bgRep from here): scrolling to the end reveals them all.
    listFlick.positionViewAtEnd()
  }

  function handleCardKey(ev) {
    if (ev.key === Qt.Key_Escape) {
      if (root.prefsOpen) { root.prefsOpen = false } else { root.closePopup() }
      ev.accepted = true; return
    }
    if (ev.key === Qt.Key_R) { root.refresh(); ev.accepted = true; return }
    if (ev.key === Qt.Key_O) {
      root.prefsOpen = !root.prefsOpen
      if (root.prefsOpen) root.readKeybind()
      ev.accepted = true; return
    }
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
  function open() { root.writePopupState(true) }
  function close() { root.closePopup() }

  // Global IPC: direct `qs ipc call omarchy.task-manager toggle` also works
  // (the keybind uses the shell dispatch above).
  IpcHandler {
    target: "omarchy.task-manager"
    function open(): void { root.writePopupState(true) }
    function show(): void { root.writePopupState(true) }
    function close(): void { root.closePopup() }
    function hide(): void { root.closePopup() }
    function toggle(): void { root.writePopupState(!root.popupOpen) }
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

  // --- Omarchy mascot: official brand path (vector, ~500 bytes, no video --
  // the plugin stays lightweight). Path data from
  // https://omarchy.org/brand/omarchy-logo.svg (viewBox 0 0 1200 1200,
  // evenodd). The brand logo has NO eyes; ours are two IDENTICAL rects,
  // perfectly symmetric around the center (positions from the mascot raster).
  component MascotFace: Item {
    id: mascot
    property color tint: "#9ece6a"
    // Per-eye openness (1 = open, 0 = fully closed) for staggered blinks.
    property real eyeOpenL: 1.0
    property real eyeOpenR: 1.0
    // Eye-roll orbit angle (degrees); 0 = eyes at rest.
    property real rollAng: 0
    // 0 = normal eyes, 1 = eyes morphed into the play triangle (veil hover).
    property real playMorph: 0
    Behavior on playMorph {
      NumberAnimation { duration: 220; easing.type: Easing.InOutCubic }
    }
    implicitWidth: 64
    implicitHeight: 64

    // Eye geometry as fractions of the item, from the 1200-unit logo:
    // eyes (400,450,73,161) and (715,450,73,161) -> SAME size, mirrored
    // around x=0.5: centers 0.5 ± 0.13125.
    readonly property real eyeW: 0.0608
    readonly property real eyeTop: 0.375
    readonly property real eyeH: 0.1342
    readonly property real eyeLx: 0.3384   // 0.5 - 0.13125 - eyeW/2
    readonly property real eyeRx: 0.6008   // 0.5 + 0.13125 - eyeW/2
    readonly property real rollR: 0.022    // eye-roll orbit radius

    // Subtle cursor pursuit: eyes lean toward the pointer (full lean at
    // ~240px, capped at 3% of the mascot size). Both surfaces (popup and
    // veils) cover the same screen with the same origin, so mapToItem(null)
    // gives comparable coordinates in every window.
    readonly property point lookTarget: {
      if (!root.cursorValid) return Qt.point(0, 0)
      var c = mascot.mapToItem(null, mascot.width / 2, mascot.height / 2)
      var dx = root.cursorX - c.x
      var dy = root.cursorY - c.y
      var d = Math.sqrt(dx * dx + dy * dy)
      if (d < 1) return Qt.point(0, 0)
      var f = Math.min(d / 240, 1) * 0.030
      return Qt.point(dx / d * f, dy / d * f)
    }
    // Smoothed: without the Behavior the eyes SNAP on the first hover (the
    // "little flash"), because look jumps from rest to full lean instantly.
    property real lookX: 0
    property real lookY: 0
    Behavior on lookX { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
    Behavior on lookY { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
    onLookTargetChanged: { lookX = lookTarget.x; lookY = lookTarget.y }

    Shape {
      x: 0
      y: 0
      width: 1200
      height: 1200
      transform: Scale {
        xScale: mascot.width / 1200
        yScale: mascot.height / 1200
      }
      ShapePath {
        fillColor: mascot.tint
        strokeColor: "transparent"
        fillRule: ShapePath.OddEvenFill
        PathSvg {
          path: "m1200 1200h-480v-80h400v-1040h-479.996v160h-400v720h720v-720h-80v-80h159.996v880h-400v160h-640v-1200h1200zm-1120-80h480v-80h-400l.004-400h-80.004zm0-560h80.004v-400h400v-80h-480.004z"
        }
      }
    }
    Rectangle {
      // Left eye. Blink squashes around its center down to a SLIT (never an
      // empty transparent hole); roll orbits and the cursor look lean on top.
      // playMorph: eyes squash and fade FIRST (first 60% of the morph), then
      // the play triangle grows in — sequencing keeps the morph clean.
      x: (mascot.eyeLx + Math.cos(mascot.rollAng * Math.PI / 180) * mascot.rollR + mascot.lookX) * parent.width
      width: mascot.eyeW * parent.width
      y: (mascot.eyeTop + mascot.eyeH * (1 - mascot.eyeOpenL) / 2
          + Math.sin(mascot.rollAng * Math.PI / 180) * mascot.rollR + mascot.lookY) * parent.height
      height: Math.max(1.2, mascot.eyeH * parent.height * mascot.eyeOpenL)
      color: mascot.tint
      opacity: 1 - Math.min(1, mascot.playMorph * 1.8)
    }
    Rectangle {
      x: (mascot.eyeRx + Math.cos(mascot.rollAng * Math.PI / 180) * mascot.rollR + mascot.lookX) * parent.width
      width: mascot.eyeW * parent.width
      y: (mascot.eyeTop + mascot.eyeH * (1 - mascot.eyeOpenR) / 2
          + Math.sin(mascot.rollAng * Math.PI / 180) * mascot.rollR + mascot.lookY) * parent.height
      height: Math.max(1.2, mascot.eyeH * parent.height * mascot.eyeOpenR)
      color: mascot.tint
      opacity: 1 - Math.min(1, mascot.playMorph * 1.8)
    }
    // Play triangle the eyes turn into: appears only after the eyes have
    // left (second half of the morph), growing from the eye midpoint. A Text
    // glyph (not a Shape path) — fonts rasterize crisply at any scale.
    Text {
      text: "\u25B6"
      color: mascot.tint
      font.pixelSize: Math.max(1, mascot.width * 0.36)
      x: parent.width * 0.5 - width / 2
      y: parent.height * 0.4417 - height / 2
      opacity: Math.max(0, (mascot.playMorph - 0.45) / 0.55)
      scale: 0.55 + 0.45 * Math.max(0, (mascot.playMorph - 0.45) / 0.55)
      transformOrigin: Item.Center
    }

    // Humanized blink cycle: 1) both eyes, 2) left first with right lagging,
    // 3) right first with left lagging, 4) eyes roll a full circle. Repeat.
    property int blinkStep: 0
    Timer {
      id: blinkTimer
      interval: 3000 + Math.random() * 4500
      running: true
      repeat: false
      onTriggered: {
        var s = mascot.blinkStep % 4
        if (s === 0) { closeL.start(); closeR.start() }
        else if (s === 1) { closeL.start(); delayR.start() }
        else if (s === 2) { closeR.start(); delayL.start() }
        else { rollAnim.start() }
        mascot.blinkStep++
        blinkTimer.interval = 3000 + Math.random() * 4500
        blinkTimer.restart()
      }
    }
    Timer { id: delayR; interval: 90; repeat: false; onTriggered: closeR.start() }
    Timer { id: delayL; interval: 90; repeat: false; onTriggered: closeL.start() }
    SequentialAnimation {
      id: closeL
      NumberAnimation { target: mascot; property: "eyeOpenL"; to: 0; duration: 110; easing.type: Easing.InQuad }
      PauseAnimation { duration: 90 }
      NumberAnimation { target: mascot; property: "eyeOpenL"; to: 1; duration: 150; easing.type: Easing.OutQuad }
    }
    SequentialAnimation {
      id: closeR
      NumberAnimation { target: mascot; property: "eyeOpenR"; to: 0; duration: 110; easing.type: Easing.InQuad }
      PauseAnimation { duration: 90 }
      NumberAnimation { target: mascot; property: "eyeOpenR"; to: 1; duration: 150; easing.type: Easing.OutQuad }
    }
    NumberAnimation {
      id: rollAnim
      target: mascot
      property: "rollAng"
      from: 0
      to: 360
      duration: 850
      easing.type: Easing.InOutQuad
      onStopped: mascot.rollAng = 0
    }
  }

  // --- Hyprland "Application Not Responding" suppression -------------------
  // Frozen apps cannot answer xdg-shell pings, so Hyprland pops its ANR
  // dialog on windows WE paused. While any app is frozen, raise the ANR
  // threshold at RUNTIME via `hyprctl eval hl.config(...)` — with lua configs
  // `hyprctl keyword` is REFUSED ("can't work with non-legacy parsers"), and
  // eval writes nothing to the user's files and dies with the compositor.
  // The original value is restored the moment nothing is frozen anymore.
  property int anrOriginal: -1
  property bool anrSuppressed: false

  Process {
    id: anrProc
    command: ["hyprctl", "getoption", "misc:anr_missed_pings", "-j"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var v = JSON.parse(text).int
          if (v > 0) root.anrOriginal = v
        } catch (e) {}
      }
    }
  }

  onFrozenCountChanged: {
    if (root.frozenCount > 0 && !root.anrSuppressed && root.anrOriginal > 0) {
      root.anrSuppressed = true
      Quickshell.execDetached(["hyprctl", "eval", "hl.config({ misc = { anr_missed_pings = 99999 } })"])
    } else if (root.frozenCount === 0 && root.anrSuppressed) {
      root.anrSuppressed = false
      Quickshell.execDetached(["hyprctl", "eval", "hl.config({ misc = { anr_missed_pings = " + root.anrOriginal + " } })"])
    }
  }

  // --- ONE persistent veil surface per screen, created at shell start. ---
  // Layer surfaces stack by creation order within a layer: because this
  // surface exists from boot, panels opened LATER (X-Panel, etc.) render
  // ABOVE it, while app windows (always below the Top layer) stay below.
  // mask: empty Region = click-through (the pill opens the manager).
  // --- ONE persistent veil surface per screen, created at shell start. ---
  // The shell preloads a second (ghost) BarWidget instance whose IpcHandler
  // never wins; without a guard BOTH instances would paint identical veils
  // (the visible "double layer" = doubled alpha). Claim ownership with a
  // pid-liveness lock; only the winner renders veils. Same-process
  // instances share $PPID, so a random token breaks the tie and the
  // write-then-reread closes the race.
  property bool veilOwner: false
  property string veilToken: ""
  // Claim ownership unless the recorded owner is provably alive: live pid AND
  // a fresh heartbeat (owner rewrites its token every 5s). A dead instance
  // under a live shell pid (QML hot-reload, plugin reload) leaves a stale
  // token; the freshness check lets the next claimant take over instead of
  // leaving popup+veils silently dead until the shell restarts.
  Process {
    id: veilClaim
    running: true
    command: ["sh", "-c", "O=\"$XDG_RUNTIME_DIR/tm-veil-owner\"; R=$(head -c4 /dev/urandom | od -An -tx4 | tr -d ' '); P=$(cat \"$O\" 2>/dev/null); NOW=$(date +%s); MT=$(stat -c %Y \"$O\" 2>/dev/null || echo 0); if [ -n \"$P\" ] && kill -0 \"${P%%:*}\" 2>/dev/null && [ $(( NOW - MT )) -lt 12 ]; then echo busy; else echo \"$PPID:$R\" > \"$O\"; sleep 0.2; [ \"$(cat \"$O\" 2>/dev/null)\" = \"$PPID:$R\" ] && echo \"owned:$PPID:$R\" || echo busy; fi"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = (text || "").trim()
        if (t.indexOf("owned:") === 0) {
          root.veilToken = t.substring(6)
          root.veilOwner = true
        } else {
          root.veilOwner = false
        }
      }
    }
  }
  // Owner heartbeat: rewrite the token so other instances see a fresh owner.
  // If the file no longer holds our token, another instance displaced us.
  Timer {
    interval: 5000
    repeat: true
    running: root.veilOwner && root.veilToken !== ""
    onTriggered: if (!veilHeartbeat.running) veilHeartbeat.running = true
  }
  Process {
    id: veilHeartbeat
    command: ["sh", "-c", "O=\"$XDG_RUNTIME_DIR/tm-veil-owner\"; printf '%s' \"" + root.veilToken + "\" > \"$O\"; sleep 0.1; [ \"$(cat \"$O\" 2>/dev/null)\" = \"" + root.veilToken + "\" ] && echo ok || echo lost"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if ((text || "").trim() === "lost") root.veilOwner = false
    }
  }

  // Cursor position for the veil mascots while the popup is closed (veils
  // are click-through, so no hover reaches them): poll hyprctl cursorpos.
  // Cheap (120ms) and only while something is actually frozen.
  Timer {
    id: cursorPoll
    interval: 120
    repeat: true
    running: root.frozenCount > 0 && !root.popupOpen
    onTriggered: if (!cursorPosProc.running) cursorPosProc.running = true
  }
  Process {
    id: cursorPosProc
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = /(-?\d+)[, ]+\s*(-?\d+)/.exec(text || "")
        if (m) {
          root.cursorX = parseInt(m[1])
          root.cursorY = parseInt(m[2])
          root.cursorValid = true
        }
      }
    }
  }

  // --- Veils as REAL floating windows (compositor z-order, not a layer) ---
  // One FloatingWindow per frozen window, floated at open by the config rule
  // in hypr/task-manager-bindings.lua (title matching fails at open; rules
  // via hyprctl eval never apply). The compositor stacks veils naturally:
  // windows opened or raised later simply paint OVER the veil — no clipping
  // shapes. A slow poll follows workspace/geometry (dispatchers work on
  // existing windows) and re-tops the veil if the frozen window got raised
  // above it (hide+show re-stacks on top).
  property string veilRetop: ""

  Variants {
    model: root.veilOwner ? root.frozenWins : []
    delegate: FloatingWindow {
      id: veilWin
      required property var modelData
      property var win: modelData
      title: "tm-veil:" + win.addr
      implicitWidth: Math.max(win.w, 1)
      implicitHeight: Math.max(win.h, 1)
      visible: true
      // The window itself must be transparent: its background color ignores
      // the content's opacity and would flash grey at screen center on map.
      color: "transparent"

      // Born transparent; faded in only AFTER the compositor confirms the
      // window sits at the frozen window's rect. A blind 90ms timer still
      // flashed the window at screen center for a frame or two.
      property real showAlpha: 0
      Timer {
        id: veilPlace
        interval: 70
        repeat: true
        onTriggered: {
          var sel = "title:^tm-veil:" + win.addr + "$"
          Quickshell.execDetached(["hyprctl", "dispatch",
            "hl.dsp.window.move({ x = " + win.x + ", y = " + win.y + ", window = \"" + sel + "\" })"])
          Quickshell.execDetached(["hyprctl", "dispatch",
            "hl.dsp.window.resize({ window = \"" + sel + "\", x = " + win.w + ", y = " + win.h + " })"])
          if (!veilPlaceCheck.running) veilPlaceCheck.running = true
        }
      }
      Process {
        id: veilPlaceCheck
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
          waitForEnd: true
          onStreamFinished: {
            try {
              var cs = JSON.parse(text)
              for (var i = 0; i < cs.length; i++) {
                if (cs[i].initialTitle === "tm-veil:" + win.addr
                    && Math.abs(cs[i].at[0] - win.x) < 4
                    && Math.abs(cs[i].at[1] - win.y) < 4
                    && Math.abs(cs[i].size[0] - win.w) < 4
                    && Math.abs(cs[i].size[1] - win.h) < 4) {
                  veilPlace.stop()
                  veilWin.showAlpha = 1
                  return
                }
              }
            } catch (e) {}
          }
        }
      }
      // Failsafe: never stay invisible (e.g. compositor settles 1px off).
      Timer {
        id: veilShowFailsafe
        interval: 1200
        onTriggered: { veilPlace.stop(); veilWin.showAlpha = 1 }
      }
      Component.onCompleted: { veilPlace.restart(); veilShowFailsafe.restart() }
      onVisibleChanged: if (visible) {
        veilWin.showAlpha = 0
        veilPlace.restart()
        veilShowFailsafe.restart()
      }

      // Re-top: the frozen window was raised above us (user clicked through).
      property string retop: root.veilRetop
      onRetopChanged: {
        if (retop.indexOf(win.addr + ":") === 0) {
          veilWin.visible = false
          Qt.callLater(function() { veilWin.visible = true })
        }
      }

      Rectangle {
        anchors.fill: parent
        opacity: veilWin.showAlpha
        color: Qt.rgba(0.42, 0.44, 0.48, 0.55)
        border.color: Qt.rgba(1, 1, 1, 0.28)
        border.width: 1
        radius: Style.cornerRadius

        // Clicks on the veil forward focus to the frozen window (it cannot
        // respond anyway — frozen); the poll re-tops the veil afterwards.
        // Hover count boosts the sync cadence so drags track closely.
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          onEntered: root.veilHoverCount++
          onExited: root.veilHoverCount = Math.max(0, root.veilHoverCount - 1)
          onPositionChanged: function(mouse) {
            root.cursorX = win.x + mouse.x
            root.cursorY = win.y + mouse.y
            root.cursorValid = true
          }
          onClicked: Quickshell.execDetached(["hyprctl", "dispatch",
            "hl.dsp.focus({ window = \"address:" + win.addr + "\" })"])
        }

        Column {
          anchors.centerIn: parent
          spacing: Style.space(4)
          // Shrink to fit small frozen windows instead of overflowing them.
          scale: Math.min(1, (win.w - 16) / 300, (win.h - 16) / 210)
          transformOrigin: Item.Center
          // Omi doubles as a RESUME button on hover: its eyes morph into the
          // play triangle (animated both ways); clicking thaws straight from
          // the veil.
          Item {
            width: 84
            height: 84
            anchors.horizontalCenter: parent.horizontalCenter
            MascotFace {
              anchors.fill: parent
              playMorph: veilPlayArea.containsMouse ? 1 : 0
            }
            MouseArea {
              id: veilPlayArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: Quickshell.execDetached([root.binPath, "thaw", String(win.pid)])
            }
          }
          // Order: Omi, APP NAME (3x, inverse block), PAUSED.
          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: veilName.implicitWidth + Style.space(20)
            height: veilName.implicitHeight + Style.space(10)
            radius: Style.cornerRadius - 2
            color: "#9ece6a"  // brand green: the veil's opposite
            Text {
              id: veilName
              anchors.centerIn: parent
              text: win.app
              color: "#1a1b26"  // theme bg: inverse of the block
              font.family: Style.font.family
              font.pixelSize: Math.round(Style.font.caption * 3)
              font.bold: true
            }
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.tr("pausedTag")
            color: "#ffffff"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }
      }
    }
  }

  // Event-driven sync: the helper streams Hyprland socket2 events so veils
  // react instantly (retop on focus of a frozen window, follow on workspace
  // moves, cleanup on close) instead of waiting for the 400ms poll.
  property bool veilEventsDead: false
  Process {
    id: veilEventsProc
    running: root.veilOwner && root.frozenCount > 0 && !root.veilEventsDead
    command: [root.binPath, "follow"]
    stdout: SplitParser {
      onRead: data => {
        if (data.startsWith("activewindowv2>>")) {
          // Event addresses lack the 0x prefix clients JSON carries.
          var addr = "0x" + data.substring(16).trim()
          for (var i = 0; i < root.frozenWins.length; i++) {
            if (root.frozenWins[i].addr === addr) {
              root.veilRetop = addr + ":" + Date.now()
              break
            }
          }
        } else {
          if (!veilSyncProc.running) veilSyncProc.running = true
          if (data.startsWith("closewindow>>") && !scanProc.running)
            scanProc.running = true
        }
      }
    }
    onExited: {
      root.veilEventsDead = true
      veilEventsRestart.restart()
    }
  }
  Timer {
    id: veilEventsRestart
    interval: 1500
    onTriggered: root.veilEventsDead = false
  }

  // Glue the veil and its frozen window in BOTH directions: whichever one
  // changed since the last sync wins, the other is moved/resized to match.
  // (Hyprland has no window groups; resizing the veil with SUPER+drag
  // otherwise resized only the veil, never the frozen app below it.)
  // Steady cadence 400ms; while a veil is hovered (likely being dragged)
  // tighten to 120ms so the frozen window tracks the drag closely.
  property int veilHoverCount: 0
  property var veilSync: ({})
  Timer {
    interval: root.veilHoverCount > 0 ? 120 : 400
    repeat: true
    running: root.veilOwner && root.frozenCount > 0
    onTriggered: if (!veilSyncProc.running) veilSyncProc.running = true
  }
  Process {
    id: veilSyncProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var cs = JSON.parse(text)
          var sync = root.veilSync
          for (var i = 0; i < root.frozenWins.length; i++) {
            var w = root.frozenWins[i]
            var rw = null, vw = null
            for (var j = 0; j < cs.length; j++) {
              if (cs[j].address === w.addr) rw = cs[j]
              else if (cs[j].initialTitle === "tm-veil:" + w.addr) vw = cs[j]
            }
            if (!rw || !vw) continue
            var last = sync[w.addr] || { x: w.x, y: w.y, w: w.w, h: w.h }
            var rr = { x: rw.at[0], y: rw.at[1], w: rw.size[0], h: rw.size[1] }
            var vr = { x: vw.at[0], y: vw.at[1], w: vw.size[0], h: vw.size[1] }
            var eq = function(a, b) {
              return Math.abs(a.x - b.x) < 3 && Math.abs(a.y - b.y) < 3
                  && Math.abs(a.w - b.w) < 3 && Math.abs(a.h - b.h) < 3
            }
            var winChanged = !eq(rr, last)
            var veilChanged = !eq(vr, last)
            var vsel = "title:^tm-veil:" + w.addr + "$"
            var wsel = "address:" + w.addr
            if (veilChanged && !winChanged && rw.floating) {
              // The user dragged/resized the VEIL: glue the real window to
              // it. Only possible when the frozen window is FLOATING —
              // tiled windows are owned by the layout, so there the veil
              // just snaps back (else branch).
              Quickshell.execDetached(["hyprctl", "dispatch",
                "hl.dsp.window.move({ x = " + vr.x + ", y = " + vr.y + ", window = \"" + wsel + "\" })"])
              Quickshell.execDetached(["hyprctl", "dispatch",
                "hl.dsp.window.resize({ window = \"" + wsel + "\", x = " + vr.w + ", y = " + vr.h + " })"])
              sync[w.addr] = vr
            } else {
              // Default: the veil follows the window (geometry + workspace).
              if (winChanged || !eq(vr, rr)) {
                Quickshell.execDetached(["hyprctl", "dispatch",
                  "hl.dsp.window.move({ x = " + rr.x + ", y = " + rr.y + ", window = \"" + vsel + "\" })"])
                Quickshell.execDetached(["hyprctl", "dispatch",
                  "hl.dsp.window.resize({ window = \"" + vsel + "\", x = " + rr.w + ", y = " + rr.h + " })"])
              }
              if (!w.pinned && rw.workspace && vw.workspace
                  && rw.workspace.id !== vw.workspace.id)
                Quickshell.execDetached(["hyprctl", "dispatch",
                  "hl.dsp.window.move({ workspace = \"" + rw.workspace.id + "\", follow = false, window = \"" + vsel + "\" })"])
              sync[w.addr] = rr
            }
          }
          root.veilSync = sync
        } catch (e) {}
        if (!veilActiveWinProc.running) veilActiveWinProc.running = true
      }
    }
  }
  Process {
    id: veilActiveWinProc
    command: ["hyprctl", "activewindow", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var a = JSON.parse(text)
          var addr = a.address || ""
          // Fire only on the TRANSITION into focusing a frozen window;
          // re-firing while it stays focused flaps the veil every poll.
          if (addr !== root.veilLastActive) {
            root.veilLastActive = addr
            for (var i = 0; i < root.frozenWins.length; i++) {
              if (root.frozenWins[i].addr === addr) {
                root.veilRetop = addr + ":" + Date.now()
                break
              }
            }
          }
        } catch (e) {}
      }
    }
  }
  property string veilLastActive: ""

  // The popup must open where the user's ATTENTION is. Focus is wrong: after
  // moving a window across monitors the focus sits on the other screen and
  // the card "disappears" there. The cursor's monitor is the right answer
  // for both the bar click and SUPER+SHIFT+T — resolved fresh at open time.
  property var popupScreen: null
  Process {
    id: cursorScreenProc
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = /(-?\d+)[, ]+\s*(-?\d+)/.exec(text || "")
        if (!m) return
        var cx = parseInt(m[1]), cy = parseInt(m[2])
        for (var i = 0; i < root.monitors.length; i++) {
          var mon = root.monitors[i]
          if (cx >= mon.x && cx < mon.x + mon.w && cy >= mon.y && cy < mon.y + mon.h) {
            for (var j = 0; j < Quickshell.screens.length; j++) {
              if (Quickshell.screens[j].name === mon.name) {
                root.popupScreen = Quickshell.screens[j]
                // Card position is relative to the popup window: a position
                // dragged on one monitor is off-center (or off-screen) on
                // another — re-center when the target screen changes.
                if (root.cardPosScreen !== mon.name) {
                  root.cardPosScreen = mon.name
                  root.cardPosSet = false
                  Qt.callLater(function() { if (!root.cardPosSet) root.centerCard() })
                }
                return
              }
            }
          }
        }
      }
    }
  }
  function focusedScreen() {
    for (var i = 0; i < root.monitors.length; i++) {
      if (!root.monitors[i].focused) continue
      for (var j = 0; j < Quickshell.screens.length; j++)
        if (Quickshell.screens[j].name === root.monitors[i].name)
          return Quickshell.screens[j]
    }
    return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  }

  // --- popup: Overlay layer, above everything, visible on all workspaces ---
  PanelWindow {
    id: popupWin
    visible: root.popupOpen && root.veilOwner
    screen: root.popupScreen ? root.popupScreen : root.focusedScreen()
    anchors { top: true; left: true; right: true; bottom: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    // Input is ALWAYS limited to the card: outside clicks and hover pass
    // through to the windows below — frozen-app veils stay interactive
    // (hover morph + Omi play-resume) while the popup is open. The popup
    // closes via the toggle keybind or the card's close button.
    mask: Region { item: card }
    WlrLayershell.namespace: "tm-popup"
    WlrLayershell.layer: WlrLayer.Overlay
    // OnDemand: the card takes keyboard only after a deliberate click on it.
    // (Exclusive would make Hyprland route ALL pointer input to this overlay
    // surface, killing hover/click on the floating veils below — verified.)
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    onWidthChanged: root.maybeCenterCard()
    onHeightChanged: root.maybeCenterCard()

    // Feeds the cursor position so the mascots' eyes can follow it (within
    // the card — the mask blocks everything outside it anyway).
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onPositionChanged: function(mouse) {
        root.cursorX = mouse.x
        root.cursorY = mouse.y
        root.cursorValid = true
      }
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
      // close area behind the card does not fire. Also feeds cursor tracking
      // (hovering the card never reaches the full-screen area).
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onPositionChanged: function(mouse) {
          root.cursorX = card.x + mouse.x
          root.cursorY = card.y + mouse.y
          root.cursorValid = true
        }
      }

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
              // Brand mascot, blinking now and then.
              MascotFace {
                width: 20
                height: 20
                anchors.verticalCenter: parent.verticalCenter
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
          // Sort: cycle RAM → CPU → name (bars + arrow reads as "sort").
          IconBtn {
            glyph: "\uF161"
            active: root.sortBy !== "ram"
            onClicked: root.cycleSort()
          }
          // Pin: keep the dialog visible (outside clicks don't close it).
          IconBtn {
            glyph: "\uF08D"
            active: root.pinned
            onClicked: root.pinned = !root.pinned
          }
          // Gear: preferences panel (shortcut, thresholds, display toggles).
          IconBtn {
            glyph: "\uF013"
            active: root.prefsOpen
            onClicked: {
              root.prefsOpen = !root.prefsOpen
              if (root.prefsOpen) root.readKeybind()
            }
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
        // Not shown when swap is zram-backed (Omarchy stock): RAM compression
        // already happens there by design.
        Rectangle {
          id: zswapBanner
          visible: !root.zswapEnabled && !root.zramBacked
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

        // --- preferences panel (gear): everything configurable lives here --
        // Replaces the process list while open; Esc backs out to the list.
        // fillHeight keeps the rows TOP-aligned (without a flexing item the
        // layout centered them vertically).
        Column {
          visible: root.prefsOpen
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(8)

          // Shortcut: OPT-IN SUPER+SHIFT+T bind — the helper script writes
          // the hyprland lua only on this explicit click (marketplace rule:
          // consent required).
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Text {
              Layout.fillWidth: true
              text: root.tr("prefsKeybind")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              text: "SUPER+SHIFT+T"
              color: root.keybindOn ? Color.accent : Qt.darker(Color.popups.text, 1.5)
              font.family: root.iconFont
              font.pixelSize: Style.font.caption
            }
            Button {
              iconText: root.keybindOn ? root.tr("prefsOn") : root.tr("prefsOff")
              bordered: true
              onClicked: root.toggleKeybind()
            }
          }

          // Bar pill display mode (icon only / numbers / numbers+graph).
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Text {
              Layout.fillWidth: true
              text: root.tr("prefsBarMode")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Button {
              iconText: root.barMode
              bordered: true
              onClicked: root.cycleBarMode()
            }
          }

          // Per-row sparklines.
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Text {
              Layout.fillWidth: true
              text: root.tr("prefsSpark")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Button {
              iconText: root.pref("sparklines", false) ? root.tr("prefsOn") : root.tr("prefsOff")
              bordered: true
              onClicked: root.setPref("sparklines", !root.pref("sparklines", false))
            }
          }

          // Watchdog: auto-pause the biggest apps when RAM used >= this.
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            property int v: root.pref("watchMaxRam", 94)
            Text {
              Layout.fillWidth: true
              text: root.tr("prefsRam")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Button {
              iconText: "−"
              bordered: true
              onClicked: if (parent.v > 50) root.setPref("watchMaxRam", parent.v - 1)
            }
            Text {
              text: parent.v + "%"
              color: Color.accent
              font.family: root.iconFont
              font.pixelSize: Style.font.caption
            }
            Button {
              iconText: "+"
              bordered: true
              onClicked: if (parent.v < 99) root.setPref("watchMaxRam", parent.v + 1)
            }
          }

          // Watchdog: CPU trigger (Off = disabled; freezes stop CPU burn).
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            property int v: root.pref("watchMaxCpu", 0)
            Text {
              Layout.fillWidth: true
              text: root.tr("prefsCpu")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Button {
              iconText: "−"
              bordered: true
              onClicked: if (parent.v > 0) root.setPref("watchMaxCpu", parent.v <= 55 ? 0 : parent.v - 5)
            }
            Text {
              text: parent.v === 0 ? root.tr("prefsOff") : parent.v + "%"
              color: Color.accent
              font.family: root.iconFont
              font.pixelSize: Style.font.caption
            }
            Button {
              iconText: "+"
              bordered: true
              onClicked: if (parent.v < 99) root.setPref("watchMaxCpu", parent.v === 0 ? 50 : parent.v + 5)
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Button {
              iconText: root.tr("prefsRefresh")
              bordered: true
              onClicked: root.refresh()
            }
            Item { Layout.fillWidth: true; height: 1 }
          }

          Text {
            width: parent.width
            text: root.tr("prefsHint")
            color: Qt.darker(Color.popups.text, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption - 1
            wrapMode: Text.WrapAnywhere
          }
        }

        // The list FLEXES: it absorbs leftover card space, so the Activity
        // section and footer pin to the bottom with no dead space.
        // A ListView (not Flickable+Repeater): delegates update IN PLACE
        // from the reconciled ListModel — no destroy/recreate flicker on
        // each 2s poll — and it scrolls natively.
        ListView {
          id: listFlick
          visible: !root.prefsOpen
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: Style.space(6)
          model: appsModel

          header: Text {
            width: listFlick.width
            visible: root.apps.length === 0
            text: root.tr("noApps")
            color: Qt.darker(Color.popups.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          delegate: Column {
            required property int index
            // Quickshell's ListView does not inject ListModel roles into
            // delegate context (neither bare names nor a per-item `model`
            // object). Bind content to the reconciled data array instead —
            // reconcileApps() keeps model order == root.apps order, and the
            // binding re-evaluates on every poll without recreating rows.
            property var app: (index < root.apps.length) ? root.apps[index] : ({})
            width: listFlick.width
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

                // Browser tabs (live, from the companion extension via the
                // native bridge) — every tab, not just the active one per
                // window. Falls back to window titles when the bridge is
                // not installed. app comes from root.apps (raw state array).
                Repeater {
                  model: root.expandedProcs[app.pid]
                         ? ((app.tabs && app.tabs.length)
                            ? app.tabs
                            : (app.wins || []).filter(function(w) { return w.title && w.title !== "" }))
                         : []
                  Text {
                    required property var modelData
                    // tab objects carry .active; window objects do not
                    readonly property bool isTab: modelData.active !== undefined
                    text: (isTab ? (modelData.active ? "▸ " : "· ") : "▸ ")
                          + (modelData.title || modelData.url || "")
                    color: isTab && modelData.active
                           ? Qt.darker(Color.popups.text, 1.05)
                           : Qt.darker(Color.popups.text, 1.15)
                    opacity: isTab && !modelData.active ? 0.75 : 1.0
                    width: parent.width - Style.space(20)
                    x: Style.space(20)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                // Expanded subprocess rows (tree view). Each row carries
                // pause + kill so a single hung thread (classic: a browser
                // tab/renderer eating RAM) can be stopped without touching
                // the rest of the family.
                Repeater {
                  model: root.subRows(app.pid)
                  Rectangle {
                    required property var modelData
                    property var proc: modelData
                    width: parent.width - Style.space(20)
                    x: Style.space(20)
                    height: subRow.implicitHeight + Style.space(4)
                    color: proc.state === "T"
                           ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
                           : "transparent"
                    radius: Style.cornerRadius - 2

                    RowLayout {
                      id: subRow
                      width: parent.width - Style.space(8)
                      anchors.centerIn: parent
                      spacing: Style.space(8)

                      Text {
                        Layout.fillWidth: true
                        // Role beats comm: chromium/electron children all
                        // share the parent's comm, the role is the real info
                        // ("renderer" = a tab, "gpu", "network", ...).
                        text: "└ " + (proc.role && proc.role !== "" ? proc.role : proc.comm)
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
                      // Single-thread control: signals on this pid only —
                      // the scope freezer would pause the WHOLE family.
                      RowBtn {
                        glyph: proc.state === "T" ? "\uDB81\uDC0A" : "\uDB80\uDFE4"
                        accent: proc.state === "T"
                        onClicked: root.action(proc.state === "T" ? "thaw-pid" : "freeze-pid", proc.pid)
                      }
                      RowBtn {
                        glyph: "\uDB80\uDD56"
                        danger: true
                        onClicked: root.action("kill-pid", proc.pid)
                      }
                    }
                  }
                }
              }
          footer: Column {
            width: listFlick.width
            spacing: Style.space(6)

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
                width: listFlick.width
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

            // --- system daemons (not ours): what eats resources when the
            // machine feels slow. Informational only — we cannot signal
            // foreign pids, so these rows carry no buttons. ---
            Text {
              visible: root.system.length > 0
              text: root.tr("system")
              color: Qt.darker(Color.popups.text, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Repeater {
              id: sysRep
              model: root.system
              Rectangle {
                required property var modelData
                property var sys: modelData
                width: listFlick.width
                height: sysRow.implicitHeight + Style.space(8)
                color: "transparent"
                radius: Style.cornerRadius - 2

                RowLayout {
                  id: sysRow
                  width: parent.width - Style.space(16)
                  anchors.centerIn: parent
                  spacing: Style.space(8)

                  Item { width: 14; height: 1 }
                  Text {
                    Layout.fillWidth: true
                    text: sys.name
                    color: Qt.darker(Color.popups.text, 1.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  Text {
                    text: (sys.procs > 1 ? sys.procs + " " + root.tr("procs") + " · " : "")
                          + sys.rss_mb + " MB"
                    color: Qt.darker(Color.popups.text, 1.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
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
          visible: root.pref("showGraphs", true) && !root.prefsOpen

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
        font.family: root.faFont
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
      // CPU: microchip + fixed-width % + its OWN sparkline (graph mode).
      Text {
        visible: root.barMode !== "off"
        text: "\uF2DB " + ("   " + root.cpuNow.toFixed(0)).slice(-3) + "%"
        color: Qt.darker(Color.foreground, 1.3)
        font.family: root.faFont
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
      // RAM: cubes (blocks) + fixed-width % + its OWN sparkline (graph mode).
      Text {
        visible: root.barMode !== "off"
        text: "\uF1B3 " + ("   " + root.memNow.toFixed(0)).slice(-3) + "%"
        color: Qt.darker(Color.foreground, 1.3)
        font.family: root.faFont
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
        root.writePopupState(!root.popupOpen)
        if (!root.popupOpen) root.refresh()
      }
    }
  }

  Component.onCompleted: root.refresh()
}
