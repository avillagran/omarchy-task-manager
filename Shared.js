.pragma library
// State shared by every BarWidget instance of this plugin in the shell.
//
// The Omarchy shell loads the widget more than once in the same process (it
// preloads a ghost BarWidget whose IpcHandler/open() calls may land there).
// A `.pragma library` script is instantiated once per QML engine, so it is
// the in-memory meeting point for those instances: no runtime files, no
// locks, nothing another process can plant or race.
//
// - owner: the one instance that renders the card and the veils and runs
//   the background helpers (two would paint everything twice).
// - popup: whether the card is open; pushed to every live instance.

var instances = []
var owner = null
var popupOpen = false

function alive(inst) {
  try {
    return inst !== null && inst.alive === true
  } catch (e) {
    return false
  }
}

function register(inst) {
  if (instances.indexOf(inst) < 0) instances.push(inst)
  inst.popupOpen = popupOpen
  return claim(inst)
}

function unregister(inst) {
  var i = instances.indexOf(inst)
  if (i >= 0) instances.splice(i, 1)
  if (owner === inst) owner = null
}

// True when `inst` owns (or just took over) rendering.
function claim(inst) {
  if (owner === inst) return true
  if (alive(owner)) return false
  owner = inst
  return true
}

function setPopup(open) {
  popupOpen = !!open
  for (var i = instances.length - 1; i >= 0; i--) {
    if (!alive(instances[i])) {
      instances.splice(i, 1)
      continue
    }
    instances[i].popupOpen = popupOpen
  }
}
