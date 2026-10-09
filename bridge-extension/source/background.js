// Omarchy Task Manager Tabs — reports the full tab list to the local
// native host on every tab change. Read-only: this extension never touches
// page content; `tabs` grants titles/URLs, nothing else.
const HOST = "io.github.avillagran.taskmanager";

async function report() {
  try {
    const tabs = await chrome.tabs.query({});
    const slim = tabs.map(t => ({
      id: t.id,
      win: t.windowId,
      title: t.title || "",
      url: t.url || "",
      active: !!t.active,
      group: t.groupId
    }));
    await chrome.runtime.sendNativeMessage(HOST, { tabs: slim });
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
report();
