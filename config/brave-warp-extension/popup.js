const statusCard = document.querySelector(".status-card");
const statusTitle = document.querySelector("#status-title");
const statusDetail = document.querySelector("#status-detail");
const enabledSwitch = document.querySelector("#enabled");
const switchLabel = document.querySelector(".switch");
const reloadButton = document.querySelector("#reload-extension");
const siteCount = document.querySelector("#site-count");
const sites = document.querySelector("#sites");
const currentSite = document.querySelector("#current-site");
const addCurrentSiteButton = document.querySelector("#add-current-site");
const resetButton = document.querySelector("#reset-hosts");
const retryButton = document.querySelector("#retry");
const errorBox = document.querySelector("#error");
const expectedBuild = globalThis.warpBuild;
let busy = false;
let hasOverrides = false;
let workerReady = false;
let currentHost = null;
let currentTabId = null;
let routedHosts = [];

function setBusy(value) {
  busy = value;
  enabledSwitch.disabled = value || !workerReady;
  reloadButton.disabled = value;
  retryButton.disabled = value || !workerReady;
  addCurrentSiteButton.disabled = value || !workerReady || !currentHost || currentTabId === null || routedHosts.includes(currentHost);
  addCurrentSiteButton.textContent = currentHost && routedHosts.includes(currentHost) ? "Routed" : "Route site";
  resetButton.disabled = value || !workerReady || !hasOverrides;
  for (const button of sites.querySelectorAll("button")) button.disabled = value || !workerReady;
}

function request(type, values = {}) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage({ type, ...values }, (response) => {
      const error = chrome.runtime.lastError?.message || response?.error;
      if (error) reject(new Error(error));
      else if (!response) reject(new Error("Extension is not responding. Restart Brave and reopen this popup."));
      else resolve(response);
    });
  });
}

function render(state) {
  enabledSwitch.checked = state.enabled;
  const nixHostsMatch = JSON.stringify(state.nixHosts) === JSON.stringify(expectedBuild?.hosts);
  workerReady = state.apiVersion === 2
    && state.extensionVersion === expectedBuild?.version
    && nixHostsMatch
    && Array.isArray(state.addedHosts)
    && Array.isArray(state.removedHosts);
  routedHosts = Array.isArray(state.hosts) ? state.hosts : [];
  hasOverrides = workerReady && (state.addedHosts.length > 0 || state.removedHosts.length > 0);
  statusCard.classList.remove("active", "issue");
  switchLabel.hidden = !workerReady;
  reloadButton.hidden = workerReady;

  if (!workerReady) {
    statusCard.classList.add("issue");
    statusTitle.textContent = "Extension update pending";
    statusDetail.textContent = nixHostsMatch
      ? "Reload the extension to update its site controls"
      : "Reload the extension to merge new Nix sites";
  } else if (!state.enabled) {
    statusTitle.textContent = "Routing paused";
    statusDetail.textContent = "Brave uses its normal proxy settings";
  } else if (state.levelOfControl !== "controlled_by_this_extension") {
    statusCard.classList.add("issue");
    statusTitle.textContent = "Routing overridden";
    statusDetail.textContent = "Another setting controls Brave's proxy";
  } else if (state.proxyError) {
    statusCard.classList.add("issue");
    statusTitle.textContent = "Proxy issue";
    statusDetail.textContent = "Last error: " + state.proxyError;
  } else {
    statusCard.classList.add("active");
    statusTitle.textContent = "Routing rules enabled";
    statusDetail.textContent = "WARP connection not verified";
  }

  sites.replaceChildren();
  siteCount.textContent = String(routedHosts.length);
  if (routedHosts.length === 0) {
    const empty = document.createElement("li");
    empty.className = "empty";
    empty.textContent = "No sites configured yet";
    sites.append(empty);
  } else {
    for (const host of routedHosts) {
      const item = document.createElement("li");
      const link = document.createElement("a");
      link.href = `https://${host}/`;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.textContent = host;
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "remove-site";
      remove.textContent = "Remove";
      remove.setAttribute("aria-label", `Remove ${host} from WARP routing`);
      remove.addEventListener("click", () => { void run("removeHost", { host }); });
      item.append(link, remove);
      sites.append(item);
    }
  }
  setBusy(busy);
}

async function reloadForNewBuild(state) {
  const fingerprint = JSON.stringify({
    expectedBuild,
    runningVersion: state.extensionVersion,
    runningHosts: state.nixHosts,
    runningApiVersion: state.apiVersion,
  });
  const { lastReloadAttempt } = await chrome.storage.local.get({ lastReloadAttempt: null });
  if (lastReloadAttempt === fingerprint) return;
  await chrome.storage.local.set({ lastReloadAttempt: fingerprint });
  statusTitle.textContent = "Updating extension…";
  statusDetail.textContent = "Reopen this popup in a moment";
  chrome.runtime.reload();
}

async function loadCurrentSite() {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab?.url) {
      currentSite.textContent = "Tab URL unavailable";
      return;
    }
    const url = new URL(tab.url);
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      currentSite.textContent = "Open an HTTP(S) site";
      return;
    }
    if (typeof tab.id !== "number") {
      currentSite.textContent = "Tab unavailable";
      return;
    }
    currentTabId = tab.id;
    currentHost = url.hostname.toLowerCase().replace(/\.$/, "");
    currentSite.textContent = currentHost;
  } catch {
    currentSite.textContent = "Cannot read this tab";
  } finally {
    setBusy(busy);
  }
}

async function run(type, values) {
  setBusy(true);
  errorBox.hidden = true;
  try {
    const state = await request(type, values);
    render(state);
    if (type === "state" && !workerReady) await reloadForNewBuild(state);
    return true;
  } catch (error) {
    errorBox.textContent = error.message;
    errorBox.hidden = false;
    return false;
  } finally {
    setBusy(false);
  }
}

enabledSwitch.addEventListener("change", () => {
  void run("setEnabled", { enabled: enabledSwitch.checked });
});
retryButton.addEventListener("click", () => { void run("retry"); });
reloadButton.addEventListener("click", () => {
  statusTitle.textContent = "Reloading extension…";
  statusDetail.textContent = "Reopen this popup in a moment";
  reloadButton.disabled = true;
  chrome.runtime.reload();
});
addCurrentSiteButton.addEventListener("click", async () => {
  const tabId = currentTabId;
  if (!await run("addHost", { host: currentHost })) return;
  try {
    await chrome.tabs.reload(tabId);
  } catch (error) {
    errorBox.textContent = `Site added, but the tab could not reload: ${error.message}`;
    errorBox.hidden = false;
  }
});
resetButton.addEventListener("click", () => { void run("resetHosts"); });
chrome.storage.onChanged.addListener((changes, area) => {
  if (!busy && area === "local" && changes.proxyError) void run("state");
});

void loadCurrentSite();
void run("state");
