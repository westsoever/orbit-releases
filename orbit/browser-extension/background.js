/**
 * Orbit Browser Companion — Tier 2 capture (URL + title + optional selection).
 * Posts to local Orbit daemon only. See orbit/browser-extension/README.md
 */
const BRIDGE = "http://127.0.0.1:8765/capture";

function shouldSkip(url) {
  if (!url) return true;
  const u = url.toLowerCase();
  return (
    u.startsWith("chrome://") ||
    u.startsWith("chrome-extension://") ||
    u.startsWith("devtools://") ||
    u.startsWith("about:") ||
    u.startsWith("edge://") ||
    u.startsWith("brave://")
  );
}

async function postTab(tab) {
  if (!tab || shouldSkip(tab.url)) return;
  let selection = "";
  try {
    const [{ result }] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => window.getSelection()?.toString()?.slice(0, 2000) || "",
    });
    selection = result || "";
  } catch {
    // activeTab may not allow scripting on restricted pages
  }
  const body = {
    url: tab.url,
    title: tab.title || "",
    tab_id: tab.id,
    selection,
    browser_name: "Browser",
    bundle_id: "browser.extension",
    timestamp: new Date().toISOString(),
  };
  try {
    await fetch(BRIDGE, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch {
    // daemon not running — silent
  }
}

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  try {
    const tab = await chrome.tabs.get(tabId);
    await postTab(tab);
  } catch {
    /* ignore */
  }
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === "complete" && tab.active) {
    postTab(tab);
  }
});
