.pragma library

function themeName(value) {
  return typeof value === "string" && value !== "." && value !== ".."
         && /^[A-Za-z0-9._-]{1,128}$/.test(value) ? value : ""
}

function edit(value, start, end, insertion) {
  var text = String(value || "").slice(0, 256)
  var a = Math.max(0, Math.min(text.length, Math.min(start, end)))
  var b = Math.max(a, Math.min(text.length, Math.max(start, end)))
  var room = 256 - (text.length - (b - a))
  var extra = String(insertion || "").replace(/[\x00-\x1f\x7f]/g, "").slice(0, room)
  return { text: text.slice(0, a) + extra + text.slice(b), cursor: a + extra.length }
}
