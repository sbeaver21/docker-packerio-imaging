/* ==========================================================================
   Image Builder - shared browser code.

   Loaded by every page, before the page's own script. It owns the parts that
   are the same everywhere:

     * the DOM helpers and the formatters;
     * transport, toasts and the error banner;
     * the connection indicator and the polling loop;
     * the theme.

   The rules that hold throughout:

     1. No HTML is ever built from a string. Every node is created with
        createElement and every value is assigned to textContent, so a project
        name or a scheduler message cannot become markup.
     2. Nothing is read from the cluster except through /api.
     3. A page draws itself from one snapshot. Each page registers a renderer,
        and every renderer is called with the same object, so nothing on screen
        can disagree with anything else on it.

   A page script does not start anything: it registers and returns, and
   App.start() begins polling once the whole document is ready.
   ========================================================================== */

"use strict";

window.App = (function () {
  const body = document.body;

  const CONFIG = {
    page: body.dataset.page || "",
    refreshSeconds: Math.max(5, Number(body.dataset.refreshSeconds) || 15),
    canMutate: body.dataset.canMutate === "true",
    logTail: Math.max(50, Number(body.dataset.logTail) || 2000),
  };

  /* ------------------------------------------------------------------------
     DOM helpers
     ------------------------------------------------------------------------ */

  /** Create an element. Props: class, text, dataset, on<Event>; anything else
   *  is an attribute. Children may be nodes, strings, or nested arrays. */
  function h(tag, props, ...children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(props || {})) {
      if (value === null || value === undefined || value === false) continue;
      if (key === "class") {
        node.className = value;
      } else if (key === "text") {
        node.textContent = String(value);
      } else if (key === "dataset") {
        Object.assign(node.dataset, value);
      } else if (key.startsWith("on") && typeof value === "function") {
        node.addEventListener(key.slice(2).toLowerCase(), value);
      } else if (value === true) {
        node.setAttribute(key, "");
      } else {
        node.setAttribute(key, String(value));
      }
    }
    append(node, children);
    return node;
  }

  function append(node, children) {
    for (const child of children.flat(Infinity)) {
      if (child === null || child === undefined || child === false) continue;
      node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
  }

  const $ = (id) => document.getElementById(id);

  /** Replace every child of `node` with `children`. */
  function fill(node, ...children) {
    node.replaceChildren();
    append(node, children);
  }

  /* ------------------------------------------------------------------------
     Formatting
     ------------------------------------------------------------------------ */

  const RELATIVE = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  const MINUTE = 60;
  const HOUR = 3600;
  const DAY = 86400;
  const MONTH = 2592000;

  /** "45s", "12m 30s", "3h 5m", "2d 4h" - a build takes tens of minutes. */
  function formatDuration(seconds) {
    if (seconds === null || seconds === undefined || Number.isNaN(seconds)) return "—";
    const value = Math.max(0, Math.round(seconds));
    if (value < MINUTE) return `${value}s`;
    const minutes = Math.floor(value / MINUTE);
    if (minutes < 60) return `${minutes}m ${value % 60}s`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ${minutes % 60}m`;
    return `${Math.floor(hours / 24)}d ${hours % 24}h`;
  }

  function formatRelative(iso) {
    if (!iso) return "—";
    const moment = new Date(iso);
    if (Number.isNaN(moment.getTime())) return "—";
    const delta = Math.round((moment.getTime() - Date.now()) / 1000);
    const magnitude = Math.abs(delta);
    if (magnitude < 45) return "just now";
    if (magnitude < HOUR) return RELATIVE.format(Math.round(delta / MINUTE), "minute");
    if (magnitude < DAY) return RELATIVE.format(Math.round(delta / HOUR), "hour");
    if (magnitude < MONTH) return RELATIVE.format(Math.round(delta / DAY), "day");
    return moment.toLocaleDateString();
  }

  function formatAbsolute(iso) {
    if (!iso) return "";
    const moment = new Date(iso);
    return Number.isNaN(moment.getTime()) ? "" : moment.toLocaleString();
  }

  /** The build arguments a run carries, for the line under its name.
   *
   * The project is deliberately not in here: every caller already prints it in
   * its own column, and repeating it made a run's row read
   * "name / scheduled - name / name".
   */
  function buildSummary(run) {
    const parameters = run.parameters || {};
    return parameters.PACKER_BUILD_ARGS || "";
  }

  const STATE_TEXT = {
    succeeded: "succeeded",
    failed: "failed",
    running: "running",
    blocked: "blocked",
    pending: "pending",
  };

  function stateLabel(state) {
    return h("span", {
      class: "state-label",
      dataset: { state: state || "pending" },
      text: STATE_TEXT[state] || state || "unknown",
    });
  }

  const HEALTH_TEXT = {
    ok: "healthy",
    failing: "failing",
    running: "running",
    suspended: "paused",
    never: "never run",
    orphan: "orphaned",
  };

  function healthBadge(health) {
    const key = HEALTH_TEXT[health] ? health : "never";
    return h(
      "span",
      { class: "health", dataset: { health: key } },
      h("span", { class: "health-dot", "aria-hidden": "true" }),
      HEALTH_TEXT[key],
    );
  }

  /** States in which a run has not finished, and a second one would queue. */
  const ACTIVE_STATES = new Set(["running", "blocked", "pending"]);

  /* ------------------------------------------------------------------------
     Transport
     ------------------------------------------------------------------------ */

  async function api(path, options) {
    const settings = options || {};
    const headers = { Accept: "application/json", ...(settings.headers || {}) };
    if (settings.body !== undefined) headers["Content-Type"] = "application/json";

    const response = await fetch(path, { ...settings, headers });
    let payload = null;
    try {
      payload = await response.json();
    } catch (error) {
      payload = null;
    }
    if (!response.ok) {
      const message =
        (payload && payload.error) || `${response.status} ${response.statusText || "request failed"}`;
      const failure = new Error(message);
      failure.status = response.status;
      throw failure;
    }
    return payload;
  }

  /* ------------------------------------------------------------------------
     Toasts and the banner
     ------------------------------------------------------------------------ */

  function toast(message, kind) {
    const host = $("toasts");
    if (!host) return;
    const item = h(
      "div",
      { class: "toast", dataset: { kind: kind || "info" } },
      h("span", { class: "toast-text", text: message }),
    );
    host.append(item);
    const remove = () => item.remove();
    const timer = setTimeout(remove, kind === "error" ? 10000 : 5000);
    item.addEventListener("click", () => {
      clearTimeout(timer);
      remove();
    });
    while (host.children.length > 4) host.firstElementChild.remove();
  }

  let bannerTimer = null;

  function showBanner(message) {
    $("banner-text").textContent = message;
    $("banner").hidden = false;
  }

  function hideBanner() {
    $("banner").hidden = true;
    $("banner-text").textContent = "";
  }

  function fail(message) {
    // A repeated poll failure must not stack identical banners; one is enough.
    if (bannerTimer) return;
    showBanner(message);
    bannerTimer = setTimeout(() => {
      bannerTimer = null;
    }, 15000);
  }

  /* ------------------------------------------------------------------------
     Connection indicator
     ------------------------------------------------------------------------ */

  function renderConnection(connected, detail) {
    const node = $("connection");
    if (!node) return;
    const label = node.querySelector(".conn-text");
    node.dataset.state = connected ? "connected" : "unavailable";
    label.textContent = connected ? "connected" : "disconnected";
    node.title = detail || "";
  }

  /* ------------------------------------------------------------------------
     Theme

     The stylesheet has two palettes: the light one on :root, and a terminal
     palette after k9s on :root[data-theme="dark"]. The head script has already
     resolved the stored preference to a concrete theme before the first paint,
     so nothing here can cause a flash - this drives the toggle and keeps
     "auto" honest when the operating system changes its mind.
     ------------------------------------------------------------------------ */

  const THEME_KEY = "aria-image-builder-theme";
  const THEME_ORDER = ["auto", "dark", "light"];
  const THEME_LABEL = {
    auto: "follow the system",
    dark: "dark",
    light: "light",
  };

  const darkQuery = window.matchMedia
    ? window.matchMedia("(prefers-color-scheme: dark)")
    : null;

  /** The ?theme= override, or null. Read-only: it never writes a preference. */
  function forcedTheme() {
    try {
      const value = new URLSearchParams(window.location.search).get("theme");
      return THEME_ORDER.includes(value) ? value : null;
    } catch (error) {
      return null;
    }
  }

  function storedTheme() {
    try {
      const raw = window.localStorage.getItem(THEME_KEY);
      return THEME_ORDER.includes(raw) ? raw : "auto";
    } catch (error) {
      // A browser with storage disabled still gets a working page, just
      // without the preference remembered.
      return "auto";
    }
  }

  function applyTheme(mode) {
    const wantsDark =
      mode === "dark" || (mode === "auto" && darkQuery !== null && darkQuery.matches);
    document.documentElement.setAttribute("data-theme", wantsDark ? "dark" : "light");
    document.documentElement.setAttribute("data-theme-mode", mode);

    const button = $("theme-button");
    if (!button) return;
    button.dataset.mode = mode;
    const label = `Theme: ${THEME_LABEL[mode]}`;
    button.setAttribute("aria-label", label);
    button.title = label;
    for (const icon of button.querySelectorAll(".theme-icon")) {
      icon.hidden = !icon.classList.contains(`theme-icon-${mode}`);
    }
  }

  function setTheme(mode) {
    try {
      window.localStorage.setItem(THEME_KEY, mode);
    } catch (error) {
      // Private browsing, or storage disabled: the theme still applies for
      // this page view, it just will not come back on the next one.
    }
    applyTheme(mode);
  }

  function wireTheme() {
    // ?theme= beats the stored preference for this page view; without this the
    // head script's choice would be undone as soon as the page finished loading.
    applyTheme(forcedTheme() || storedTheme());

    const button = $("theme-button");
    if (button) {
      button.addEventListener("click", () => {
        const current = button.dataset.mode || "auto";
        const next = THEME_ORDER[(THEME_ORDER.indexOf(current) + 1) % THEME_ORDER.length];
        // A click is a decision, so drop the one-off override: the address bar
        // must not claim a theme the page no longer shows.
        if (forcedTheme() !== null) {
          try {
            const url = new URL(window.location.href);
            url.searchParams.delete("theme");
            window.history.replaceState(null, "", url);
          } catch (error) {
            // Not worth failing over; the stored preference is still correct.
          }
        }
        setTheme(next);
      });
    }

    if (darkQuery === null) return;
    const followSystem = () => {
      if ((document.documentElement.getAttribute("data-theme-mode") || "auto") === "auto") {
        applyTheme("auto");
      }
    };
    if (darkQuery.addEventListener) {
      darkQuery.addEventListener("change", followSystem);
    } else if (darkQuery.addListener) {
      // Safari before 14.
      darkQuery.addListener(followSystem);
    }
  }

  /* ------------------------------------------------------------------------
     The snapshot pipeline
     ------------------------------------------------------------------------ */

  const renderers = [];
  let snapshot = null;

  /** Register a function to draw this page from a snapshot. */
  function onSnapshot(renderer) {
    renderers.push(renderer);
  }

  function render(next) {
    snapshot = next;
    renderConnection(true, `Kubernetes ${next.serverVersion || "(version unknown)"}`);
    hideBanner();

    $("foot-namespace").textContent = next.namespace;
    $("foot-refresh").textContent = String(next.refreshSeconds || CONFIG.refreshSeconds);
    $("foot-updated").textContent = `updated ${formatRelative(next.generatedAt)}`;

    for (const draw of renderers) draw(next);
  }

  let refreshing = false;

  async function refresh() {
    if (refreshing) return;
    refreshing = true;
    try {
      render(await api("/api/overview"));
    } catch (error) {
      renderConnection(false, error.message);
      fail(`Cannot read the cluster: ${error.message}`);
    } finally {
      refreshing = false;
    }
  }

  async function checkHealth() {
    try {
      const health = await api("/api/health");
      if (health.kubernetes === "connected") {
        renderConnection(true, `Kubernetes ${health.serverVersion || ""}`.trim());
      } else {
        renderConnection(false, health.error || "the API server is not reachable");
        if (health.error) fail(`The cluster is not reachable: ${health.error}`);
      }
    } catch (error) {
      renderConnection(false, error.message);
      fail(`The image builder is not answering: ${error.message}`);
    }
  }

  let pollTimer = null;

  function scheduleRefresh() {
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = setTimeout(async () => {
      if (!document.hidden) await refresh();
      scheduleRefresh();
    }, CONFIG.refreshSeconds * 1000);
  }

  /** The snapshot most recently drawn, or null before the first one. */
  function current() {
    return snapshot;
  }

  /* ------------------------------------------------------------------------
     Wiring and start-up
     ------------------------------------------------------------------------ */

  function wireChrome() {
    const refreshButton = $("refresh-button");
    if (refreshButton) {
      refreshButton.addEventListener("click", async () => {
        await checkHealth();
        await refresh();
      });
    }

    const bannerClose = $("banner-close");
    if (bannerClose) bannerClose.addEventListener("click", hideBanner);

    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) refresh();
    });
  }

  function start() {
    wireTheme();
    wireChrome();
    checkHealth().then(refresh).then(scheduleRefresh);
  }

  return {
    CONFIG,
    ACTIVE_STATES,
    h,
    append,
    fill,
    $,
    api,
    toast,
    fail,
    hideBanner,
    formatDuration,
    formatRelative,
    formatAbsolute,
    buildSummary,
    stateLabel,
    healthBadge,
    renderConnection,
    onSnapshot,
    current,
    refresh,
    start,
  };
})();
