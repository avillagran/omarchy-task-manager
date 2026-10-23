// Omarchy Task Manager: freeze/resume memory-hogging apps.
// - Pill: tasks glyph + red badge (or live CPU/MEM stats, eye toggle).
// - Popup: draggable Overlay-layer card above all windows, all workspaces.
// - Frozen apps get a grey veil exactly over their windows.
// - Process tree per app, per-row sparklines, historical CPU/RAM graph.
import QtQuick 6.11
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import "Shared.js" as Shared

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
  // Popup visibility is SHARED across instances in memory (Shared.js). The
  // shell preloads a ghost BarWidget instance and its IpcHandler/open()
  // calls can land on the ghost (whose popup would be invisible); only the
  // owner instance renders the card.
  property bool popupOpen: false
  function writePopupState(opened) {
    Shared.setPopup(opened)
    // The light engine's watch samples per-app CPU only while this is 1.
    Quickshell.execDetached([root.binPath, "popup", opened ? "1" : "0"])
  }
  property bool pinned: false
  property var prefs: ({})
  property var hist: ({})
  property real cpuNow: 0.0
  property real memNow: 0.0
  property var expandedProcs: ({})
  property var suggestions: []
  property var procsRaw: ({})
  property var procsData: ({})
  property var procsQueue: []
  property int pendingProcsPid: 0
  readonly property string binDir: (typeof manifest !== 'undefined' && manifest.__sourceDir)
                                   ? manifest.__sourceDir.replace(/\/$/, '') + '/bin'
                                   : Qt.resolvedUrl("bin").toString().replace("file://", "")
  readonly property string rustPath: root.binDir + "/task-manager-launch.sh"
  readonly property string lightPath: root.binDir + "/task-manager-light.sh"
  readonly property string buildPath: root.binDir + "/task-manager-build.sh"

  // --- engines --------------------------------------------------------------
  // Light: bin/task-manager.py on the stock Python, nothing to build; it runs
  // every command from the first second. Full: the Rust engine built locally
  // from bin/task-manager-rs (offline, locked; a no-op when the binary already
  // matches the source), which adds the memory governor and keeps per-app
  // history while the card is closed. Both speak the same commands and JSON.
  // engineState: "checking" → "ready" (Rust built) | "nocargo" | "failed" |
  // "skipped" (the user keeps the light engine).
  property string engineState: "checking"
  property bool buildAsked: false
  readonly property bool lightChosen: root.pref("engine", "auto") === "light"
  readonly property bool engineFull: root.engineState === "ready" && !root.lightChosen
  readonly property bool engineReady: true
  // Long-running helpers (watch, follow) wait until the engine is settled so
  // they start once, on the engine that stays.
  readonly property bool engineSettled: root.engineState !== "checking"
  readonly property string binPath: root.engineFull ? root.rustPath : root.lightPath
  property string engineError: ""
  Process {
    id: engineBuild
    command: root.capped(16384, 900, [root.buildPath])
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.engineError = (text || "").slice(0, 16384).trim().slice(-600)
    }
    onExited: function(code) {
      root.engineState = code === 0 ? "ready" : (code === 127 ? "nocargo" : "failed")
      root.refresh()
    }
  }
  function buildEngine() {
    if (engineBuild.running) return
    root.engineState = "checking"
    root.engineError = ""
    engineBuild.running = true
  }
  // Called once the first state (and with it the saved prefs) is known: a
  // user who keeps the light engine never pays for a cargo build.
  function settleEngine() {
    if (root.buildAsked) return
    root.buildAsked = true
    if (root.lightChosen) root.engineState = "skipped"
    else root.buildEngine()
  }
  function chooseEngine(light) {
    root.setPref("engine", light ? "light" : "auto")
    if (!light && root.engineState !== "ready") root.buildEngine()
  }
  // Switching engines restarts the long-running helpers on the new one.
  onBinPathChanged: {
    if (watchProc.running) root.watchDead = true
    if (veilEventsProc.running) root.veilEventsDead = true
  }

  // --- bounded subprocess output -------------------------------------------
  // Every collected command runs under a timeout and a byte ceiling: argv
  // is passed as positional parameters (never spliced into the shell
  // program), stderr is discarded, the exit status survives the pipe, and
  // output that reaches the ceiling is rejected by clip().
  function capped(bytes, seconds, argv) {
    return ["sh", "-c", "set -o pipefail; timeout -k 1 " + seconds + " \"$@\" 2>/dev/null | head -c " + (bytes + 1),
            "sh"].concat(argv)
  }
  function clip(text, bytes) {
    var t = text || ""
    return t.length > bytes ? "" : t
  }
  readonly property int capSmall: 65536
  readonly property int capJson: 4194304

  // Process identity for every action: pid plus its kernel start time, so a
  // recycled pid can never receive a signal meant for an exited process.
  function tok(p) {
    if (!p || !(p.pid > 0)) return "0"
    return (p.start > 0) ? (p.pid + ":" + p.start) : String(p.pid)
  }

  // Values spliced into Hyprland Lua dispatch strings: only plain integers
  // and window addresses, so compositor data can never inject Lua.
  function luaInt(v) {
    var n = Math.round(Number(v))
    return isFinite(n) ? String(Math.max(-1000000, Math.min(1000000, n))) : "0"
  }
  function safeAddr(a) {
    return (/^0x[0-9a-fA-F]{1,16}$/.test(a || "")) ? a : ""
  }

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
    command: root.capped(262144, 5, ["head", "-c", "262145", "--", Qt.resolvedUrl("i18n.json").toString().replace("file://", "")])
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.i18n = JSON.parse(root.clip(text, 262144) || "{}") } catch (e) {} }
    }
  }

  // Icon toggle button with an explicit monospace (Nerd Font) glyph —
  // qs.Ui Button's font has no MDI private-use glyphs (renders tofu).
  component IconBtn: Rectangle {
    id: ib
    property string glyph: ""
    property bool active: false
    property bool danger: false
    // Shown under the button on hover (right-aligned: buttons sit at the
    // card's right edge).
    property string hint: ""
    // Keyboard modifiers of the last click (SUPER+click = forced reset).
    property int mods: 0
    signal clicked()
    width: 26
    height: 26
    radius: 5
    z: ibMa.containsMouse ? 10 : 0
    color: danger ? Qt.rgba(1, 0.42, 0.38, 0.18)
                  : active ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16) : "transparent"
    border.color: danger ? "#ff6b60"
                         : active ? Color.accent
                                  : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.30)
    border.width: 1
    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: parent.glyph
      color: parent.danger ? "#ff6b60" : parent.active ? Color.accent : Color.popups.text
      font.family: root.iconFont
      font.pixelSize: Style.font.body
    }
    MouseArea {
      id: ibMa
      anchors.fill: parent
      hoverEnabled: ib.hint !== ""
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) { ib.mods = mouse.modifiers; ib.clicked() }
    }
    Rectangle {
      visible: ibMa.containsMouse && ib.hint !== ""
      anchors.right: parent.right
      anchors.top: parent.bottom
      anchors.topMargin: 4
      width: Math.min(hintText.implicitWidth, 280) + 12
      height: hintText.implicitHeight + 8
      radius: 4
      color: Color.popups.background
      border.color: ib.danger ? "#ff6b60" : Color.popups.border
      border.width: 1
      Text {
        textFormat: Text.PlainText
        id: hintText
        anchors.centerIn: parent
        width: Math.min(implicitWidth, 280)
        text: ib.hint
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
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
      textFormat: Text.PlainText
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

  // App icon from its desktop entry; a lettered tile when there is none.
  component AppIcon: Item {
    id: ai
    property string cls: ""
    property string name: ""
    property bool dim: false
    property int size: 20
    implicitWidth: size
    implicitHeight: size
    Layout.alignment: Qt.AlignVCenter
    readonly property string src: { root.iconEpoch; return root.iconFor(ai.cls, ai.name) }
    Image {
      id: aiImg
      anchors.fill: parent
      source: ai.src
      sourceSize.width: ai.size * 2
      sourceSize.height: ai.size * 2
      asynchronous: true
      smooth: true
      visible: status === Image.Ready
      opacity: ai.dim ? 0.45 : 1
    }
    Rectangle {
      anchors.fill: parent
      visible: aiImg.status !== Image.Ready
      radius: 5
      color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, ai.dim ? 0.10 : 0.22)
      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: (ai.name || "?").charAt(0).toUpperCase()
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Math.round(ai.size * 0.55)
        font.bold: true
      }
    }
  }

  // Right-aligned number column: one width in the header and every row, so
  // the CPU and RAM figures line up.
  component ValueCell: Text {
    property int cellWidth: 56
    Layout.preferredWidth: cellWidth
    Layout.minimumWidth: cellWidth
    Layout.alignment: Qt.AlignVCenter
    horizontalAlignment: Text.AlignRight
    textFormat: Text.PlainText
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    elide: Text.ElideLeft
  }

  // Small rounded tag ("PAUSED") and clickable filter chip.
  component Pill: Rectangle {
    property string label: ""
    property color tint: Color.accent
    implicitWidth: pillText.implicitWidth + 10
    implicitHeight: pillText.implicitHeight + 2
    radius: height / 2
    color: Qt.rgba(tint.r, tint.g, tint.b, 0.18)
    Text {
      id: pillText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: parent.label
      color: parent.tint
      font.family: Style.font.family
      font.pixelSize: Style.font.caption - 2
      font.bold: true
    }
  }
  component Chip: Rectangle {
    id: chip
    property string label: ""
    property bool active: false
    signal clicked()
    implicitWidth: chipText.implicitWidth + 16
    implicitHeight: 22
    radius: 11
    color: active ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
                  : chipMa.containsMouse ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.08)
                                         : "transparent"
    border.color: active ? Color.accent : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.25)
    border.width: 1
    Text {
      id: chipText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: chip.label
      color: chip.active ? Color.accent : Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      id: chipMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }
  // Clickable column title; the active sort column carries the arrow.
  component ColHead: Text {
    property string key: ""
    property int cellWidth: 56
    property bool alignEnd: true
    Layout.preferredWidth: cellWidth
    Layout.minimumWidth: cellWidth
    horizontalAlignment: alignEnd ? Text.AlignRight : Text.AlignLeft
    textFormat: Text.PlainText
    text: root.tr("col_" + key) + (root.sortBy === key ? (root.sortFlipped !== (key === "name") ? " ▴" : " ▾") : "")
    color: root.sortBy === key ? Color.accent : Qt.darker(Color.popups.text, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption - 1
    font.bold: true
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.setSort(parent.key)
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
    // Card closed: `--brief` skips the background/system scans nobody sees
    // (the veils and the badge only need the windowed apps).
    command: root.capped(root.capJson, 10, [root.binPath, "state"].concat(root.popupOpen ? [] : ["--brief"]))
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.parseState(root.clip(text, root.capJson))
        root.settleEngine()
        if (root.rescanWanted) {
          root.rescanWanted = false
          Qt.callLater(root.refresh)
        }
      }
    }
  }

  Process {
    id: histProc
    command: root.capped(root.capJson, 10, [root.binPath, "history"])
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.hist = JSON.parse(root.clip(text, root.capJson) || "{}")
        } catch (e) {}
      }
    }
  }

  Process {
    id: procsProc
    command: root.capped(root.capJson, 10, [root.binPath, "procs", "0"])
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Only touch the model when the data actually changed: assigning a
        // fresh array on every fetch rebuilds every expanded row, which
        // redraws the list and resets the scroll position.
        var pid = root.pendingProcsPid
        var raw = (root.clip(text, root.capJson) || "[]").trim()
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
    procsProc.command = root.capped(root.capJson, 10, [root.binPath, "procs", root.tok(root.appByPid(pid))])
    procsProc.running = true
  }
  function appByPid(pid) {
    for (var i = 0; i < root.allApps.length; i++) if (root.allApps[i].pid === pid) return root.allApps[i]
    return { "pid": pid }
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

  // List sort order: "ram" (default) / "cpu" / "name". Clicking the active
  // column header again flips the direction (session only).
  property string sortBy: {
    var s = root.prefs["sortBy"]
    return (s === "cpu" || s === "name") ? s : "ram"
  }
  property bool sortFlipped: false
  function cycleSort() {
    setSort(sortBy === "ram" ? "cpu" : (sortBy === "cpu" ? "name" : "ram"))
  }
  function setSort(by) {
    if (by === root.sortBy) {
      root.sortFlipped = !root.sortFlipped
    } else {
      root.sortFlipped = false
      setPref("sortBy", by)
    }
    root.applyView()
  }
  function sortRows(arr) {
    var sb = root.sortBy, flip = root.sortFlipped ? -1 : 1
    return arr.slice().sort(function(a, b) {
      var d = sb === "name" ? a.name.localeCompare(b.name)
            : sb === "cpu" ? cpuVal(b.hkey || b.unit, b.pid) - cpuVal(a.hkey || a.unit, a.pid)
            : (b.rss_mb + (b.swap_mb || 0)) - (a.rss_mb + (a.swap_mb || 0))
      return d * flip
    })
  }

  // Search box + quick filters ("all" | "paused" | "cpu" | "ram"), applied
  // to every list on the client side.
  readonly property int cpuColW: 48
  readonly property int ramColW: 66
  property string filterText: ""
  property string quickFilter: "all"
  onFilterTextChanged: root.applyView()
  onQuickFilterChanged: root.applyView()
  function rowMatches(r) {
    var q = root.filterText.trim().toLowerCase()
    if (q !== "" && (r.name + " " + (r.title || "") + " " + r.pid).toLowerCase().indexOf(q) < 0)
      return false
    if (root.quickFilter === "paused") return !!r.frozen
    if (root.quickFilter === "cpu") return cpuVal(r.hkey || r.unit, r.pid) >= 5
    if (root.quickFilter === "ram") return (r.rss_mb || 0) >= 500
    return true
  }
  property var allApps: []
  property var allBackground: []
  property var allSystem: []
  function applyView() {
    root.apps = root.sortRows(root.allApps.filter(root.rowMatches))
    root.reconcileApps(root.apps)
    root.background = root.sortRows(root.allBackground.filter(root.rowMatches))
    root.system = root.quickFilter === "all" || root.quickFilter === "ram"
                  ? root.allSystem.filter(root.rowMatches) : []
  }

  // App icons from the desktop entries (window class first, then the
  // process name); a lettered tile when no entry is found.
  property var iconCache: ({})
  property int iconEpoch: 0
  function iconFor(cls, name) {
    var key = (cls || "") + "|" + (name || "")
    if (root.iconCache[key] !== undefined) return root.iconCache[key]
    var src = ""
    var tries = [cls, cls ? cls.toLowerCase() : "", name]
    for (var i = 0; i < tries.length && src === ""; i++) {
      if (!tries[i]) continue
      var e = DesktopEntries.heuristicLookup(tries[i])
      if (e && e.icon) src = Quickshell.iconPath(e.icon, true)
      if (src === "") src = Quickshell.iconPath(tries[i], true)
    }
    // Entries load asynchronously: remember misses only once they exist.
    if (src !== "" || DesktopEntries.applications.values.length > 0) root.iconCache[key] = src
    return src
  }
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.iconCache = ({}); root.iconEpoch++ }
  }

  // Value colours: calm text, then warmer as a row weighs more.
  function cpuColor(v) {
    return v >= 50 ? "#f7768e" : v >= 15 ? "#ff9e64" : v >= 5 ? "#e0af68" : Color.popups.text
  }
  // Sparkline bar colour: the CPU column's scale for that sample, so a
  // past spike reads at a glance; dimmed for frozen and system rows.
  function sparkColor(frac, muted) {
    var c = root.cpuColor(frac * 100)
    return muted ? Qt.darker(c, 1.6) : c
  }
  function memColor(mb) {
    return mb >= 2048 ? "#f7768e" : mb >= 1024 ? "#ff9e64" : mb >= 400 ? "#e0af68" : Color.popups.text
  }
  function usageColor(pct) {
    return pct >= 90 ? "#f7768e" : pct >= 75 ? "#ff9e64" : pct >= 50 ? "#e0af68" : "#9ece6a"
  }
  function fmtMem(mb) {
    return mb >= 1024 ? (mb / 1024).toFixed(mb >= 10240 ? 0 : 1) + " GB" : Math.round(mb) + " MB"
  }

  // Last N samples of an app's CPU series as 0..1 fractions on a fixed
  // 0-100% scale (same units as the CPU column, % of one core like top): a
  // full bar is a whole core, so rows compare and nothing rescales.
  function sparkFor(unit, pid, n) {
    var key = (unit && unit.length > 0) ? unit : ("pid" + pid)
    var h = root.hist
    if (!h || !h.apps || !h.apps[key]) return []
    var series = h.apps[key].cpu || []
    if (series.length === 0) return []
    var out = []
    var start = Math.max(0, series.length - n)
    for (var j = start; j < series.length; j++) out.push(Math.max(0, Math.min(1, series[j] / 100)))
    return out
  }

  // Engine hints carry their numbers; the words come from i18n.json so
  // they follow the card's language. "text" is the English fallback.
  function sugText(sg) {
    if (sg.kind === "sleeper" && sg.name !== undefined)
      return root.tr("sugSleeper").arg(sg.name).arg(sg.swap_mb)
    if (sg.kind === "governor" && sg.count !== undefined)
      return root.tr("sugGovernor").arg(sg.count).arg(sg.names)
    return sg.text || ""
  }

  function parseState(text) {
    try {
      var data = JSON.parse(text)
      root.engineKind = data.engine === "python" ? "python" : "rust"
      root.allApps = data.apps || []
      // A brief scan (card closed) carries no background/system rows: keep
      // the last full lists so the card never opens on empty sections.
      if (!root.scanBrief) {
        // History key of each group: "bg:<name>" (its biggest pid changes
        // between ticks, the name doesn't; a shared scope would mix in the
        // windowed app's CPU). Matches the engines' sample_history.
        var bgRows = data.background || []
        for (var bi = 0; bi < bgRows.length; bi++)
          bgRows[bi].hkey = "bg:" + bgRows[bi].name
        root.allBackground = bgRows
        var sysRows = data.system || []
        for (var si = 0; si < sysRows.length; si++)
          sysRows[si].hkey = "sys:" + sysRows[si].name
        root.allSystem = sysRows
      }
      root.monitors = data.monitors || []
      // Workspaces currently shown on some monitor. A frozen window on a
      // HIDDEN workspace (scratchpad/special, another ws) must not get a
      // veil: there is nothing visible to cover, and the veil would map at
      // stale coords (screen center flash) or linger under the window when
      // it comes back. When the window returns to a visible ws, the scan
      // recreates the veil — a fresh map, so it lands ON TOP again.
      var activeWs = {}
      for (var mi = 0; mi < root.monitors.length; mi++)
        activeWs[root.monitors[mi].active_ws] = true
      var n = 0
      var fw = []
      for (var i = 0; i < root.allApps.length; i++) {
        var a = root.allApps[i]
        if (a.frozen) {
          n++
          var wins = a.wins || []
          for (var j = 0; j < wins.length; j++) {
            var w = wins[j]
            if (!w.pinned && !activeWs[w.ws])
              continue
            fw.push({
              "addr": w.addr, "x": w.x, "y": w.y, "w": w.w, "h": w.h,
              "ws": w.ws, "mon": w.mon, "pinned": w.pinned,
              "app": a.name, "pid": a.pid, "start": a.start || 0
            })
          }
        }
      }
      root.frozenCount = n
      // Assign only on real change: Variants rebuilds delegates when the
      // array identity flips, which would strobe every veil on each scan.
      if (JSON.stringify(fw) !== JSON.stringify(root.frozenWins))
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
      root.suggestions = data.suggestions || []
      root.prefs = data.prefs || {}
      root.memUsedPct = root.memTotalMb > 0 ? Math.round((root.memTotalMb - root.memAvailMb) * 100 / root.memTotalMb) : 0
      root.swapTotalMb = data.mem ? (data.mem.swap_total_mb || 0) : 0
      root.applyView()
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
      root.allApps = []
      root.apps = []
      root.frozenWins = []
      root.frozenCount = 0
    }
  }

  // "rust" or "python": which engine answered the last scan.
  property string engineKind: ""
  property int memUsedPct: 0
  property int swapTotalMb: 0
  property bool scanBrief: false
  property bool rescanWanted: false
  function refresh() {
    if (scanProc.running) { root.rescanWanted = true; return }
    root.scanBrief = !root.popupOpen
    scanProc.running = true
  }

  function refreshHistory() {
    if (root.engineReady && !histProc.running) histProc.running = true
  }

  // `target` is the process object from the engine's JSON (pid + start).
  function action(verb, target) {
    if (!root.engineReady) return
    Quickshell.execDetached([root.binPath, verb, root.tok(target)])
    settleTimer.restart()
    // Thaw does NOT steal focus: the user clicks the window (or the row's
    // name) when THEY want it focused.
  }

  function resumeAll() {
    for (var i = 0; i < root.allApps.length; i++) {
      if (root.allApps[i].frozen) {
        root.action("thaw", root.allApps[i])
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

  // --- emergency tools: stuck windows and a stuck shell --------------------
  // Click-to-kill is Hyprland's own kill mode (xkill for Wayland): the next
  // click SIGKILLs the clicked window's process, Esc cancels. Compositor-
  // side, so it works on apps too hung to answer anything. The card is a
  // full-screen layer and would catch that click itself: close it first.
  Timer {
    id: killModeTimer
    interval: 250
    onTriggered: Quickshell.execDetached(["hyprctl", "kill"])
  }
  function killByClick() {
    root.closePopup()
    killModeTimer.restart()
  }

  // Shell reset: omarchy-restart-shell. Holding SUPER (or having pressed it
  // in the last few seconds, in case Hyprland's SUPER+drag bind eats the
  // click) turns it into the forced reset: shell, supervisor and helpers
  // SIGKILLed, then a fresh shell. The engine detaches into its own session
  // first, since this shell is the one about to die.
  property bool superHeld: false
  readonly property bool forceArmed: root.superHeld || forceArmTimer.running
  Timer {
    id: forceArmTimer
    interval: 4000
  }
  function isSuperKey(key) {
    return key === Qt.Key_Super_L || key === Qt.Key_Super_R || key === Qt.Key_Meta
  }
  function shellReset(mods) {
    var force = root.forceArmed || (mods & Qt.MetaModifier) !== 0
    root.superHeld = false
    forceArmTimer.stop()
    // Without the engine the normal reset still works: it is Omarchy's own.
    if (!root.engineReady) {
      Quickshell.execDetached(["omarchy-restart-shell"])
      return
    }
    Quickshell.execDetached(force ? [root.binPath, "shell-reset", "force"]
                                  : [root.binPath, "shell-reset"])
  }

  function closePopup() {
    root.superHeld = false
    forceArmTimer.stop()
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
      // No ownership yet? Re-probe: a dead owner instance is claimable now,
      // so the popup can actually render.
      if (!root.veilOwner) root.veilOwner = Shared.claim(root)
      if (!root.cardPosSet) root.centerCard()
      root.refresh()
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
    if (root.isSuperKey(ev.key)) { root.superHeld = true; return }
    if (ev.key === Qt.Key_K) { root.killByClick(); ev.accepted = true; return }
    if (ev.key === Qt.Key_Slash) { searchField.forceActiveFocus(); ev.accepted = true; return }
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
        root.action(bg.frozen ? "thaw" : "freeze", bg)
        ev.accepted = true
      } else if (ev.key === Qt.Key_X || ev.key === Qt.Key_Delete) {
        root.action("kill", bg)
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
      root.action("focus", app)
      ev.accepted = true
    } else if (ev.key === Qt.Key_Space || ev.key === Qt.Key_P) {
      root.action(app.frozen ? "thaw" : "freeze", app)
      ev.accepted = true
    } else if (ev.key === Qt.Key_X || ev.key === Qt.Key_Delete) {
      root.action("kill", app)
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

  // --- optional Hyprland additions (keybinds, veil rule) -------------------
  // Nothing is written from here. "Apply"/"Remove" open a terminal where
  // bin/task-manager-configure.sh shows the exact change to ~/.config/hypr
  // and asks first. Bind status is read back from Hyprland itself (`binds`).
  // The reset bind embeds the plugin path in a Lua string: offered only for
  // paths that need no escaping.
  readonly property bool launcherPathSafe: /^\/[A-Za-z0-9._\/+@-]+$/.test(root.binDir)
  // "Apply"/"Remove": a terminal explains what will change in the user's
  // Hyprland config and asks before touching anything
  // (bin/task-manager-configure.sh). Arguments are fixed words; the script
  // path is checked to need no quoting, since the launcher runs it via bash.
  readonly property string configurePath: root.binDir + "/task-manager-configure.sh"
  function configure(what, action) {
    if (!/^\/[A-Za-z0-9._\/+@-]+$/.test(root.configurePath)) return
    if (["show", "reset", "veil"].indexOf(what) < 0 || ["apply", "remove"].indexOf(action) < 0) return
    root.closePopup()
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             root.configurePath + " " + what + " " + action])
    bindsRecheck.count = 0
    bindsRecheck.restart()
  }
  // Pick up the result once the user answered (Hyprland reloads on change).
  Timer {
    id: bindsRecheck
    property int count: 0
    interval: 2000
    repeat: true
    onTriggered: {
      root.readKeybind()
      if (++count >= 45) stop()
    }
  }
  property bool keybindOn: false
  property bool resetKeybindOn: false
  Process {
    id: bindsProc
    command: root.capped(root.capSmall, 5, [root.binPath, "binds"])
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var b = JSON.parse(root.clip(text, root.capSmall) || "{}")
          root.keybindOn = b.show === true
          root.resetKeybindOn = b.reset === true
        } catch (e) {}
      }
    }
  }
  function readKeybind() {
    if (root.engineReady && !bindsProc.running) bindsProc.running = true
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
    command: root.capped(root.capSmall, 2, ["hyprctl", "getoption", "misc:anr_missed_pings", "-j"])
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var v = JSON.parse(root.clip(text, root.capSmall)).int
          if (Number.isInteger(v) && v > 0 && v <= 100000) root.anrOriginal = v
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
      Quickshell.execDetached(["hyprctl", "eval", "hl.config({ misc = { anr_missed_pings = " + root.luaInt(root.anrOriginal) + " } })"])
    }
  }

  // --- owner election (in memory, Shared.js) -------------------------------
  // The shell preloads a second (ghost) BarWidget instance; without a guard
  // BOTH would paint the card and identical veils (doubled alpha) and run
  // the background helpers twice. The first live instance owns all of it;
  // when it goes away (plugin reload) the next claim hands ownership over.
  readonly property bool alive: true
  property bool veilOwner: false
  Timer {
    interval: 2000
    repeat: true
    running: !root.veilOwner
    onTriggered: root.veilOwner = Shared.claim(root)
  }
  Component.onDestruction: Shared.unregister(root)

  // Watchdog + memory governor: a child of this shell, only in the owner.
  // `--lifeline` makes the engine release every limit it set and resume
  // everything it paused as soon as the shell (its stdin) goes away.
  property bool watchDead: false
  Process {
    id: watchProc
    running: root.veilOwner && root.engineSettled && !root.watchDead && root.pref("watchdog", true)
    command: [root.binPath, "watch", "--lifeline"]
    stdinEnabled: true
    onExited: {
      root.watchDead = true
      watchRestart.restart()
    }
  }
  Timer {
    id: watchRestart
    interval: 10000
    onTriggered: root.watchDead = false
  }

  // Cursor position for the veil mascots while the popup is closed (veils
  // are click-through, so no hover reaches them): poll hyprctl cursorpos.
  // Cheap (120ms) and only while something is actually frozen.
  Timer {
    id: cursorPoll
    interval: 120
    repeat: true
    running: root.frozenCount > 0 && !root.popupOpen && root.veilOwner && root.veilsOn
    onTriggered: if (!cursorPosProc.running) cursorPosProc.running = true
  }
  Process {
    id: cursorPosProc
    command: root.capped(256, 2, ["hyprctl", "cursorpos"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = /^(-?\d{1,6})[, ]+\s*(-?\d{1,6})\s*$/.exec(root.clip(text, 256))
        if (m) {
          root.cursorX = parseInt(m[1])
          root.cursorY = parseInt(m[2])
          root.cursorValid = true
        }
      }
    }
  }

  // --- Veils as REAL floating windows (compositor z-order, not a layer) ---
  // One FloatingWindow per frozen window, floated at open by the user's
  // window rule (the veil rule from the gear panel; title matching fails at open, rules via
  // hyprctl eval never apply). The compositor stacks veils naturally:
  // windows opened or raised later simply paint OVER the veil — no clipping
  // shapes. A slow poll follows workspace/geometry (dispatchers work on
  // existing windows) and re-tops the veil if the frozen window got raised
  // above it (hide+show re-stacks on top).
  property string veilRetop: ""
  // Veils need the window rule from the gear panel (Apply rule) in the
  // user's Hyprland config; without it they would open as tiled windows.
  // So they stay off until the user turns them on there.
  readonly property bool veilsOn: root.pref("veils", false) === true

  Variants {
    model: (root.veilOwner && root.veilsOn) ? root.frozenWins : []
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
          var addr = root.safeAddr(win.addr)
          if (addr === "") { stop(); return }
          var sel = "title:^tm-veil:" + addr + "$"
          Quickshell.execDetached(["hyprctl", "dispatch",
            "hl.dsp.window.move({ x = " + root.luaInt(win.x) + ", y = " + root.luaInt(win.y) + ", window = \"" + sel + "\" })"])
          Quickshell.execDetached(["hyprctl", "dispatch",
            "hl.dsp.window.resize({ window = \"" + sel + "\", x = " + root.luaInt(win.w) + ", y = " + root.luaInt(win.h) + " })"])
          if (!veilPlaceCheck.running) veilPlaceCheck.running = true
        }
      }
      Process {
        id: veilPlaceCheck
        command: root.capped(root.capJson, 3, ["hyprctl", "clients", "-j"])
        stdout: StdioCollector {
          waitForEnd: true
          onStreamFinished: {
            try {
              var cs = JSON.parse(root.clip(text, root.capJson))
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
          onClicked: if (root.safeAddr(win.addr) !== "") Quickshell.execDetached(["hyprctl", "dispatch",
            "hl.dsp.focus({ window = \"address:" + root.safeAddr(win.addr) + "\" })"])
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
            OmiFace {
              anchors.fill: parent
              cursorX: root.cursorX
              cursorY: root.cursorY
              cursorValid: root.cursorValid
              playMorph: veilPlayArea.containsMouse ? 1 : 0
            }
            MouseArea {
              id: veilPlayArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.action("thaw", win)
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
              textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
    running: root.veilOwner && root.veilsOn && root.engineSettled && root.frozenCount > 0 && !root.veilEventsDead
    command: [root.binPath, "follow"]
    stdout: SplitParser {
      onRead: data => {
        // The engine caps event lines; anything longer is not one of ours.
        if (data.length > 4096) return
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
          // Workspace transitions change veil VISIBILITY (a frozen window
          // leaving/entering a visible workspace), not just geometry — the
          // scan rebuilds frozenWins fast instead of waiting 3s.
          if ((data.startsWith("closewindow>>") || data.startsWith("movewindowv2>>")
               || data.startsWith("workspace>>") || data.startsWith("openwindow>>"))
              && !scanProc.running)
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
    running: root.veilOwner && root.veilsOn && root.frozenCount > 0
    onTriggered: if (!veilSyncProc.running) veilSyncProc.running = true
  }
  Process {
    id: veilSyncProc
    command: root.capped(root.capJson, 3, ["hyprctl", "clients", "-j"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var cs = JSON.parse(root.clip(text, root.capJson))
          if (!Array.isArray(cs)) return
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
            var addr = root.safeAddr(w.addr)
            if (addr === "") continue
            var vsel = "title:^tm-veil:" + addr + "$"
            var wsel = "address:" + addr
            if (veilChanged && !winChanged && rw.floating) {
              // The user dragged/resized the VEIL: glue the real window to
              // it. Only possible when the frozen window is FLOATING —
              // tiled windows are owned by the layout, so there the veil
              // just snaps back (else branch).
              Quickshell.execDetached(["hyprctl", "dispatch",
                "hl.dsp.window.move({ x = " + root.luaInt(vr.x) + ", y = " + root.luaInt(vr.y) + ", window = \"" + wsel + "\" })"])
              Quickshell.execDetached(["hyprctl", "dispatch",
                "hl.dsp.window.resize({ window = \"" + wsel + "\", x = " + root.luaInt(vr.w) + ", y = " + root.luaInt(vr.h) + " })"])
              sync[w.addr] = vr
            } else {
              // Default: the veil follows the window (geometry + workspace).
              if (winChanged || !eq(vr, rr)) {
                Quickshell.execDetached(["hyprctl", "dispatch",
                  "hl.dsp.window.move({ x = " + root.luaInt(rr.x) + ", y = " + root.luaInt(rr.y) + ", window = \"" + vsel + "\" })"])
                Quickshell.execDetached(["hyprctl", "dispatch",
                  "hl.dsp.window.resize({ window = \"" + vsel + "\", x = " + root.luaInt(rr.w) + ", y = " + root.luaInt(rr.h) + " })"])
              }
              if (!w.pinned && rw.workspace && vw.workspace
                  && rw.workspace.id !== vw.workspace.id)
                Quickshell.execDetached(["hyprctl", "dispatch",
                  "hl.dsp.window.move({ workspace = \"" + root.luaInt(rw.workspace.id) + "\", follow = false, window = \"" + vsel + "\" })"])
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
    command: root.capped(root.capSmall, 2, ["hyprctl", "activewindow", "-j"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var a = JSON.parse(root.clip(text, root.capSmall))
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
    command: root.capped(256, 2, ["hyprctl", "cursorpos"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = /^(-?\d{1,6})[, ]+\s*(-?\d{1,6})\s*$/.exec(root.clip(text, 256))
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
      Keys.onReleased: function(ev) {
        if (root.isSuperKey(ev.key) && root.superHeld) {
          root.superHeld = false
          forceArmTimer.restart()
        }
      }

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
          z: 5  // button hints overlap the rows below

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
                textFormat: Text.PlainText
                text: "\u28BF"  // ⠿ drag handle
                color: Qt.darker(Color.popups.text, 1.8)
                font.family: root.iconFont
                font.pixelSize: Style.font.subtitle
              }
              // Brand mascot, blinking now and then.
              OmiFace {
                width: 20
                height: 20
                cursorX: root.cursorX
                cursorY: root.cursorY
                cursorValid: root.cursorValid
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                id: hdrTitle
                text: root.tr("title")
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }
          }
          // Click-to-kill a stuck window (Hyprland kill mode).
          IconBtn {
            glyph: "\uF05B"
            hint: root.tr("killClickHint")
            onClicked: root.killByClick()
          }
          // Shell reset; red bolt while SUPER arms the forced reset.
          IconBtn {
            id: shellResetBtn
            glyph: root.forceArmed ? "\uF0E7" : "\uF021"
            danger: root.forceArmed
            hint: root.forceArmed ? root.tr("shellResetForceHint") : root.tr("shellResetHint")
            onClicked: root.shellReset(shellResetBtn.mods)
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

        // Memory at a glance: used share as a bar coloured by how full it
        // is, then the numbers behind it.
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(4)
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            Text {
              textFormat: Text.PlainText
              text: "RAM " + root.memUsedPct + "%"
              color: root.usageColor(root.memUsedPct)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.fmtMem(root.memTotalMb - root.memAvailMb) + " / " + root.fmtMem(root.memTotalMb)
                    + (root.swapUsedMb > 50 ? "   ·   Swap " + root.fmtMem(root.swapUsedMb) : "")
                    + "   ·   PSI " + root.psiSome10.toFixed(1)
              color: Qt.darker(Color.popups.text, 1.3)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
            Pill {
              visible: root.frozenCount > 0
              label: root.frozenCount + " " + root.tr("paused")
            }
            Pill {
              visible: root.engineKind === "python"
              tint: Qt.darker(Color.popups.text, 1.3)
              label: root.tr("engineLightTag")
            }
          }
          Rectangle {
            Layout.fillWidth: true
            height: 6
            radius: 3
            color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.12)
            Rectangle {
              width: parent.width * Math.max(0, Math.min(100, root.memUsedPct)) / 100
              height: parent.height
              radius: 3
              color: root.usageColor(root.memUsedPct)
              Behavior on width { NumberAnimation { duration: 250 } }
            }
          }
        }

        Rectangle {
          Layout.fillWidth: true
          height: 1
          color: Color.popups.border
        }

        // Engine banner: the full engine was wanted but did not build. The
        // light engine keeps everything working; say so, with the reason.
        Rectangle {
          visible: root.engineState === "failed" && !root.lightChosen && !root.prefsOpen
          Layout.fillWidth: true
          height: engineCol.implicitHeight + Style.space(16)
          color: Qt.rgba(0.95, 0.65, 0.15, 0.12)
          border.color: Qt.rgba(0.95, 0.65, 0.15, 0.5)
          border.width: 1
          radius: Style.cornerRadius - 2

          Column {
            id: engineCol
            width: parent.width - Style.space(16)
            anchors.centerIn: parent
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.tr("engineFailed")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.engineError !== ""
              text: root.engineError
              color: Qt.darker(Color.popups.text, 1.5)
              font.family: root.iconFont
              font.pixelSize: Style.font.caption - 1
              wrapMode: Text.WrapAnywhere
              maximumLineCount: 8
              elide: Text.ElideRight
            }
            Button {
              iconText: root.tr("engineRetry")
              bordered: true
              onClicked: root.buildEngine()
            }
          }
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
              textFormat: Text.PlainText
              width: parent.width
              text: root.zswapAvailable ? root.tr("zswapWarn") : root.tr("zswapNoKernel")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.zswapAvailable
              text: root.tr("zswapHow")
              color: Qt.darker(Color.popups.text, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption - 1
              wrapMode: Text.WordWrap
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

          // Engine choice: light (Python, nothing to build) or full (Rust,
          // built locally when cargo is installed).
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.tr("engineLabel")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Chip {
              label: root.tr("engineLightName")
              active: !root.engineFull
              onClicked: root.chooseEngine(true)
            }
            Chip {
              label: root.tr("engineFullName")
              active: root.engineFull
              onClicked: root.chooseEngine(false)
            }
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.engineFull ? root.tr("engineFullNote")
                  : root.lightChosen ? root.tr("engineLightNote")
                  : root.engineState === "checking" ? root.tr("engineBuilding")
                  : root.engineState === "nocargo" ? root.tr("engineNoCargo")
                  : root.tr("engineFailed")
            color: Qt.darker(Color.popups.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption - 1
            wrapMode: Text.WordWrap
          }

          // Optional Hyprland snippets: the plugin never edits the user's
          // config. "Copy" puts the line on the clipboard; the user pastes it
          // into ~/.config/hypr/bindings.lua. Status comes from Hyprland.
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.tr("prefsSnippetHint")
            color: Qt.darker(Color.popups.text, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption - 1
            wrapMode: Text.WordWrap
          }
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.tr("prefsKeybind")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Text {
              textFormat: Text.PlainText
              text: "SUPER+SHIFT+T"
              color: root.keybindOn ? Color.accent : Qt.darker(Color.popups.text, 1.5)
              font.family: root.iconFont
              font.pixelSize: Style.font.caption
            }
            Button {
              iconText: root.keybindOn ? root.tr("remove") : root.tr("apply")
              bordered: true
              onClicked: root.configure("show", root.keybindOn ? "remove" : "apply")
            }
          }

          // Emergency shortcut: forced shell reset, handled by Hyprland so it
          // works even when this shell is too frozen to click.
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            visible: root.launcherPathSafe
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.tr("prefsResetKeybind")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Text {
              textFormat: Text.PlainText
              text: "SUPER+CTRL+SHIFT+DEL"
              color: root.resetKeybindOn ? "#ff6b60" : Qt.darker(Color.popups.text, 1.5)
              font.family: root.iconFont
              font.pixelSize: Style.font.caption
            }
            Button {
              iconText: root.resetKeybindOn ? root.tr("remove") : root.tr("apply")
              bordered: true
              onClicked: root.configure("reset", root.resetKeybindOn ? "remove" : "apply")
            }
          }

          // Veils over paused windows: need the window rule first.
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.tr("prefsVeils")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Button {
              iconText: root.tr("applyRule")
              bordered: true
              onClicked: root.configure("veil", "apply")
            }
            Button {
              iconText: root.veilsOn ? root.tr("prefsOn") : root.tr("prefsOff")
              bordered: true
              onClicked: root.setPref("veils", !root.veilsOn)
            }
          }

          // Watchdog + memory governor (runs inside this shell).
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.tr("prefsWatchdog")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Button {
              iconText: root.pref("watchdog", true) ? root.tr("prefsOn") : root.tr("prefsOff")
              bordered: true
              onClicked: root.setPref("watchdog", !root.pref("watchdog", true))
            }
          }

          // Bar pill display mode (icon only / numbers / numbers+graph).
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            Text {
              textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
            textFormat: Text.PlainText
            width: parent.width
            text: root.tr("prefsHint")
            color: Qt.darker(Color.popups.text, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption - 1
            wrapMode: Text.WrapAnywhere
          }
        }

        // Suggestions: evidence-based hints from the engine (sleepers in
        // swap, high pressure). Only the kill action is offered here.
        // One compact line each, so they never push the list off the card.
        // "Memory pressure is high" is left out: the RAM bar already says it.
        Repeater {
          model: root.prefsOpen ? [] : root.suggestions.filter(function(sg) { return sg.kind !== "pressure" }).slice(0, 4)
          Rectangle {
            required property var modelData
            Layout.fillWidth: true
            height: sugRow.implicitHeight + Style.space(4)
            radius: Style.cornerRadius - 2
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
            RowLayout {
              id: sugRow
              width: parent.width - Style.space(12)
              anchors.centerIn: parent
              spacing: Style.space(8)
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "💡 " + root.sugText(modelData)
                color: Qt.darker(Color.popups.text, 1.15)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 1
                elide: Text.ElideRight
              }
              RowBtn {
                visible: modelData.action === "kill"
                glyph: "\uDB80\uDD56"
                danger: true
                onClicked: root.action("kill", modelData)
              }
            }
          }
        }

        // Search + quick filters, then the column titles (click to sort).
        RowLayout {
          visible: !root.prefsOpen
          Layout.fillWidth: true
          spacing: Style.space(6)
          TextField {
            id: searchField
            Layout.fillWidth: true
            Layout.preferredHeight: 26
            verticalPadding: 2
            font.pixelSize: Style.font.caption
            foreground: Color.popups.text
            placeholderText: root.tr("searchHint")
            onTextChanged: root.filterText = text
            Keys.onEscapePressed: { text = ""; card.forceActiveFocus() }
            Keys.onReturnPressed: card.forceActiveFocus()
          }
          Repeater {
            model: [["all", root.tr("fAll")], ["paused", root.tr("fPaused")],
                    ["cpu", "CPU ≥ 5%"], ["ram", "RAM ≥ 500 MB"]]
            Chip {
              required property var modelData
              label: modelData[1]
              active: root.quickFilter === modelData[0]
              onClicked: root.quickFilter = modelData[0]
            }
          }
        }
        RowLayout {
          visible: !root.prefsOpen
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(8)
          Layout.rightMargin: Style.space(8)
          spacing: Style.space(8)
          Item { Layout.preferredWidth: 14 + 20 + Style.space(8); height: 1 }
          ColHead { key: "name"; alignEnd: false; Layout.fillWidth: true }
          Item { visible: root.pref("sparklines", false); Layout.preferredWidth: 50; height: 1 }
          ColHead { key: "cpu"; cellWidth: root.cpuColW }
          ColHead { key: "ram"; cellWidth: root.ramColW }
          Item { Layout.preferredWidth: 44 + Style.space(8); height: 1 }
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
            textFormat: Text.PlainText
            width: listFlick.width
            // An invisible header still takes its height in a ListView.
            height: visible ? implicitHeight + Style.space(6) : 0
            visible: root.apps.length === 0 && root.engineReady
            text: root.filterText !== "" || root.quickFilter !== "all" ? root.tr("noMatch") : root.tr("noApps")
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
                        textFormat: Text.PlainText
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

                    AppIcon {
                      cls: app["class"] || ""
                      name: app.name || ""
                      dim: !!app.frozen
                    }

                    // Click the app name/title to focus its window.
                    MouseArea {
                      Layout.fillWidth: true
                      Layout.preferredHeight: nameCol.implicitHeight
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.action("focus", app)

                      Column {
                        id: nameCol
                        width: parent.width
                        spacing: Style.space(2)

                        RowLayout {
                          width: parent.width
                          spacing: Style.space(6)
                          Text {
                            textFormat: Text.PlainText
                            Layout.maximumWidth: nameCol.width - (pausedPill.visible ? pausedPill.width + Style.space(6) : 0)
                            text: app.name || ""
                            color: app.frozen ? Qt.darker(Color.popups.text, 1.6) : Color.popups.text
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            font.bold: true
                            elide: Text.ElideRight
                          }
                          Pill {
                            id: pausedPill
                            visible: !!app.frozen
                            label: root.tr("pausedTag")
                          }
                          Item { Layout.fillWidth: true; height: 1 }
                        }
                        Text {
                          textFormat: Text.PlainText
                          width: parent.width
                          text: (app.title || "")
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
                        for (var i = 0; i < sd.length; i++) {
                          ctx.fillStyle = root.sparkColor(sd[i], app.frozen)
                          var bh = Math.max(1, sd[i] * height)
                          ctx.fillRect(i * bw, height - bh, Math.max(1, bw - 1), bh)
                        }
                      }
                    }

                    ValueCell {
                      cellWidth: root.cpuColW
                      property real v: root.cpuVal(app.unit, app.pid)
                      text: root.cpuFor(app.unit, app.pid) || "—"
                      color: app.frozen ? Qt.darker(Color.popups.text, 1.6) : root.cpuColor(v)
                    }
                    ValueCell {
                      cellWidth: root.ramColW
                      text: root.fmtMem(app.rss_mb || 0)
                      color: app.frozen ? Qt.darker(Color.popups.text, 1.6) : root.memColor(app.rss_mb || 0)
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                    RowBtn {
                      glyph: app.frozen ? "\uDB81\uDC0A" : "\uDB80\uDFE4"
                      accent: app.frozen
                      onClicked: root.action(app.frozen ? "thaw" : "freeze", app)
                    }
                    RowBtn {
                      glyph: "\uDB80\uDD56"
                      danger: true
                      onClicked: root.action("kill", app)
                    }
                  }
                }

                // Window titles of the expanded app (one row per window).
                Repeater {
                  model: root.expandedProcs[app.pid]
                         ? (app.wins || []).filter(function(w) { return w.title && w.title !== "" }).slice(0, 64)
                         : []
                  Rectangle {
                    required property var modelData
                    width: parent.width - Style.space(20)
                    x: Style.space(32)
                    height: Math.max(winText.implicitHeight, 16) + Style.space(2)
                    color: "transparent"
                    Text {
                      textFormat: Text.PlainText
                      id: winText
                      width: parent.width
                      text: "▸ " + parent.modelData.title
                      color: Qt.darker(Color.popups.text, 1.15)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
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
                        textFormat: Text.PlainText
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
                        textFormat: Text.PlainText
                        text: proc.state
                        color: proc.state === "T" ? Color.accent
                               : (proc.state === "Z" ? "#ff3b30"
                               : (proc.state === "R" ? "#f5c211"
                               : Qt.darker(Color.popups.text, 1.6)))
                        font.family: root.iconFont
                        font.pixelSize: Style.font.caption
                        font.bold: proc.state === "T" || proc.state === "Z" || proc.state === "R"
                      }
                      Text {
                        textFormat: Text.PlainText
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
                        onClicked: root.action(proc.state === "T" ? "thaw-pid" : "freeze-pid", proc)
                      }
                      RowBtn {
                        glyph: "\uDB80\uDD56"
                        danger: true
                        onClicked: root.action("kill-pid", proc)
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
              textFormat: Text.PlainText
              visible: root.background.length > 0
              text: root.tr("background") + "  ·  " + root.background.length
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
                  AppIcon {
                    name: bg.name || ""
                    dim: !!bg.frozen
                  }
                  Column {
                    id: bgNameCol
                    Layout.fillWidth: true
                    spacing: 0
                    RowLayout {
                      width: parent.width
                      spacing: Style.space(6)
                      Text {
                        textFormat: Text.PlainText
                        Layout.maximumWidth: bgNameCol.width - (bgPill.visible ? bgPill.width + Style.space(6) : 0)
                        text: bg.name || ""
                        color: bg.frozen ? Qt.darker(Color.popups.text, 1.6) : Color.popups.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        elide: Text.ElideRight
                      }
                      Pill {
                        id: bgPill
                        visible: !!bg.frozen
                        label: root.tr("pausedTag")
                      }
                      Item { Layout.fillWidth: true; height: 1 }
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      visible: text !== ""
                      text: (bg.procs > 1 ? bg.procs + " " + root.tr("procs") : "")
                            + (bg.procs > 1 && bg.swap_mb > 0 ? "  ·  " : "")
                            + (bg.swap_mb > 0 ? "swap " + root.fmtMem(bg.swap_mb) : "")
                      color: Qt.darker(Color.popups.text, 1.5)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption - 1
                      elide: Text.ElideRight
                    }
                  }
                  // Same sparkline as the windowed rows.
                  Canvas {
                    width: 50
                    height: 14
                    visible: root.pref("sparklines", false)
                    Layout.alignment: Qt.AlignVCenter
                    property var sd: root.sparkFor(bg.hkey, bg.pid, 24)
                    onSdChanged: requestPaint()
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      if (!sd || sd.length === 0) return
                      var bw = width / sd.length
                      for (var i = 0; i < sd.length; i++) {
                        ctx.fillStyle = root.sparkColor(sd[i], bg.frozen)
                        var bh = Math.max(1, sd[i] * height)
                        ctx.fillRect(i * bw, height - bh, Math.max(1, bw - 1), bh)
                      }
                    }
                  }
                  ValueCell {
                    cellWidth: root.cpuColW
                    property real v: root.cpuVal(bg.hkey, bg.pid)
                    text: root.cpuFor(bg.hkey, bg.pid) || "—"
                    color: bg.frozen ? Qt.darker(Color.popups.text, 1.6) : root.cpuColor(v)
                  }
                  ValueCell {
                    cellWidth: root.ramColW
                    text: root.fmtMem(bg.rss_mb || 0)
                    color: bg.frozen ? Qt.darker(Color.popups.text, 1.6) : root.memColor(bg.rss_mb || 0)
                    font.bold: true
                  }
                  // Pause (scope or signal fallback) + kill, on every row.
                  RowBtn {
                    glyph: bg.frozen ? "\uDB81\uDC0A" : "\uDB80\uDFE4"
                    accent: bg.frozen
                    onClicked: root.action(bg.frozen ? "thaw" : "freeze", bg)
                  }
                  RowBtn {
                    glyph: "\uDB80\uDD56"
                    danger: true
                    onClicked: root.action("kill", bg)
                  }
                }
              }
            }

            // --- system daemons (not ours): what eats resources when the
            // machine feels slow. Informational only — we cannot signal
            // foreign pids, so these rows carry no buttons. ---
            Text {
              textFormat: Text.PlainText
              visible: root.system.length > 0
              text: root.tr("system") + "  ·  " + root.system.length
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
                  AppIcon {
                    name: sys.name || ""
                    dim: true
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: (sys.name || "") + (sys.procs > 1 ? "  ·  " + sys.procs + " " + root.tr("procs") : "")
                    color: Qt.darker(Color.popups.text, 1.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  // Muted sparkline + CPU%: informational, like the row.
                  Canvas {
                    width: 50
                    height: 14
                    visible: root.pref("sparklines", false)
                    Layout.alignment: Qt.AlignVCenter
                    property var sd: root.sparkFor(sys.hkey, sys.pid, 24)
                    onSdChanged: requestPaint()
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      if (!sd || sd.length === 0) return
                      var bw = width / sd.length
                      for (var i = 0; i < sd.length; i++) {
                        ctx.fillStyle = root.sparkColor(sd[i], true)
                        var bh = Math.max(1, sd[i] * height)
                        ctx.fillRect(i * bw, height - bh, Math.max(1, bw - 1), bh)
                      }
                    }
                  }
                  ValueCell {
                    cellWidth: root.cpuColW
                    text: root.cpuFor(sys.hkey, sys.pid) || "—"
                    color: Qt.darker(Color.popups.text, 1.6)
                  }
                  ValueCell {
                    cellWidth: root.ramColW
                    text: root.fmtMem(sys.rss_mb || 0)
                    color: Qt.darker(Color.popups.text, 1.6)
                  }
                  // Same width as the action buttons of the rows above.
                  Item { Layout.preferredWidth: 44 + Style.space(8); height: 1 }
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
              textFormat: Text.PlainText
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

          ActivityGraph {
            width: parent.width
            spacing: Style.space(4)
            hist: root.hist
            showCores: root.pref("graphDetail", false)
            textColor: Color.popups.text
            accentColor: Color.accent
          }
          Text {
            textFormat: Text.PlainText
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
          textFormat: Text.PlainText
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
          textFormat: Text.PlainText
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
        textFormat: Text.PlainText
        text: "\uF0AE"
        color: root.frozenCount > 0 ? Color.accent : Color.foreground
        font.family: root.faFont
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
      // CPU: microchip + fixed-width % + its OWN sparkline (graph mode).
      Text {
        textFormat: Text.PlainText
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
        textFormat: Text.PlainText
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
        textFormat: Text.PlainText
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

  Component.onCompleted: {
    root.veilOwner = Shared.register(root)
    Quickshell.execDetached([root.lightPath, "popup", "0"])
    root.refresh()
  }
}
