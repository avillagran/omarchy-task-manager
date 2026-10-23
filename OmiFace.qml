// --- Omarchy mascot: official brand path (vector, ~500 bytes, no video --
// the plugin stays lightweight). Path data from
// https://omarchy.org/brand/omarchy-logo.svg (viewBox 0 0 1200 1200,
// evenodd). The brand logo has NO eyes; ours are two IDENTICAL rects,
// perfectly symmetric around the center (positions from the mascot raster).
//
// Standalone (QtQuick + Shapes only) so other plugins, such as the Omarchy
// Control Panel, can load it straight from this plugin's folder.
import QtQuick 6.11
import QtQuick.Shapes

Item {
  id: mascot
  property color tint: "#9ece6a"
  // Cursor in window coordinates (mapToItem(null) space); the eyes lean
  // toward it while cursorValid. Hosts feed these from their hover areas.
  property real cursorX: 0
  property real cursorY: 0
  property bool cursorValid: false
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
    if (!mascot.cursorValid) return Qt.point(0, 0)
    var c = mascot.mapToItem(null, mascot.width / 2, mascot.height / 2)
    var dx = mascot.cursorX - c.x
    var dy = mascot.cursorY - c.y
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
    textFormat: Text.PlainText
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
