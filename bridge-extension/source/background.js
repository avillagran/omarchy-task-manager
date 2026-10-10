// Omarchy Task Manager Tabs — reports the full tab list to the local
// native host on every tab change, and executes local commands coming back
// (discard a tab = unload it from memory, it reloads on focus).
// Read-only on page content: `tabs` grants titles/URLs, nothing else.
const HOST = "io.github.avillagran.taskmanager";
let port = null;

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (_) { port = null; return; }
  port.onMessage.addListener(async (msg) => {
    if (msg && msg.action === "discard" && typeof msg.tabId === "number") {
      try { await chrome.tabs.discard(msg.tabId); } catch (_) {}
      report();
    } else if (msg && msg.action === "discard-background") {
      try {
        const tabs = await chrome.tabs.query({ active: false, discarded: false });
        for (const t of tabs) {
          try { await chrome.tabs.discard(t.id); } catch (_) {}
        }
      } catch (_) {}
      report();
    }
  });
  port.onDisconnect.addListener(() => { port = null; setTimeout(connect, 5000); });
}

async function report() {
  try {
    const tabs = await chrome.tabs.query({});
    const slim = tabs.map(t => ({
      id: t.id,
      win: t.windowId,
      title: t.title || "",
      url: t.url || "",
      active: !!t.active,
      discarded: !!t.discarded,
      audible: !!t.audible,
      loading: t.status === "loading",
      group: t.groupId
    }));
    if (port) port.postMessage({ tabs: slim });
  } catch (_) { /* host not installed yet — retry on next event */ }
}

chrome.tabs.onCreated.addListener(report);
chrome.tabs.onRemoved.addListener(report);
chrome.tabs.onUpdated.addListener(report);
chrome.tabs.onActivated.addListener(report);
chrome.tabs.onMoved.addListener(report);
chrome.tabs.onAttached.addListener(report);
chrome.tabs.onDetached.addListener(report);
chrome.windows.onCreated.addListener(report);
chrome.windows.onRemoved.addListener(report);
chrome.runtime.onStartup.addListener(report);
chrome.runtime.onInstalled.addListener(report);
connect();
report();
