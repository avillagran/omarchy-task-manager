// Historical CPU/RAM graph fed by `task-manager history` (the watchdog's
// ring buffer): RAM as a muted line, CPU in the accent, plus an optional
// per-core mini-graph with its own 0-100% scale below the main one.
//
// Standalone (QtQuick only, colors passed in) so other plugins, such as the
// Omarchy Control Panel, can load it straight from this plugin's folder.
import QtQuick 6.11

Column {
  id: graph
  // {cpu: [..], mem: [..], cores: [[..], ..]} — percentages, oldest first.
  property var hist: ({})
  property bool showCores: false
  property color textColor: "#c0caf5"
  property color accentColor: "#9ece6a"
  property int graphHeight: 96
  property int coresHeight: 52

  spacing: 4
  onHistChanged: { graphCanvas.requestPaint(); coresCanvas.requestPaint() }
  onTextColorChanged: { graphCanvas.requestPaint(); coresCanvas.requestPaint() }
  onAccentColorChanged: { graphCanvas.requestPaint(); coresCanvas.requestPaint() }

  Canvas {
    id: graphCanvas
    width: parent.width
    height: graph.graphHeight
    onWidthChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height
      var hst = graph.hist
      var fg = graph.textColor
      ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.15)
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
      ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.55)
      ctx.lineWidth = 1.5
      ctx.beginPath()
      for (var m = 0; m < Math.min(mems.length, n); m++) {
        var ym = h - Math.min(100, mems[m]) / 100 * h
        if (m === 0) ctx.moveTo(m * xstep, ym)
        else ctx.lineTo(m * xstep, ym)
      }
      ctx.stroke()
      ctx.strokeStyle = graph.accentColor
      ctx.lineWidth = 2
      ctx.beginPath()
      for (var k = 0; k < n; k++) {
        var yk = h - Math.min(100, series[k]) / 100 * h
        if (k === 0) ctx.moveTo(k * xstep, yk)
        else ctx.lineTo(k * xstep, yk)
      }
      ctx.stroke()
    }
    Component.onCompleted: requestPaint()
  }

  // Per-core detail: its OWN mini-graph with its own 0-100% scale,
  // below the main one. Alternating tints separate adjacent cores.
  Canvas {
    id: coresCanvas
    width: parent.width
    height: graph.coresHeight
    visible: graph.showCores
    onVisibleChanged: if (visible) requestPaint()
    onWidthChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height
      var hst = graph.hist
      var fg = graph.textColor, ac = graph.accentColor
      if (!hst || !hst.cores || hst.cores.length < 2) return
      var n = hst.cores.length
      var last = hst.cores[n - 1]
      if (!last) return
      var ncores = last.length
      var xstep = w / (n - 1)
      ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.10)
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(0, h / 2)
      ctx.lineTo(w, h / 2)
      ctx.stroke()
      for (var c = 0; c < ncores; c++) {
        ctx.strokeStyle = (c % 2 === 0)
          ? Qt.rgba(ac.r, ac.g, ac.b, 0.55)
          : Qt.rgba(fg.r, fg.g, fg.b, 0.35)
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
    Component.onCompleted: requestPaint()
  }
}
