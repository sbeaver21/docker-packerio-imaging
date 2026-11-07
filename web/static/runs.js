/* ==========================================================================
   The Runs page: every Job, the filters on top, a log viewer, and delete.

   The filters live in the address bar as well as in the controls, so a link to
   "the failed runs of one project" is a link someone can send to a colleague.
   The Build page uses that: its Runs button points at /runs?project=<name>.
   ========================================================================== */

"use strict";

(function () {
  const {
    CONFIG,
    ACTIVE_STATES,
    h,
    fill,
    $,
    api,
    toast,
    formatDuration,
    formatRelative,
    formatAbsolute,
    buildSummary,
    stateLabel,
    onSnapshot,
    current,
    refresh,
    start,
  } = window.App;

  const FILTERS = new Set(["all", "active", "failed", "succeeded"]);

  const view = {
    runFilter: "all",
    projectFilter: "all",
  };

  /* ------------------------------------------------------------------------
     Filters
     ------------------------------------------------------------------------ */

  /** Take the starting filters from the query string, ignoring nonsense. */
  function readFiltersFromUrl() {
    let params = null;
    try {
      params = new URLSearchParams(window.location.search);
    } catch (error) {
      return;
    }
    const show = params.get("show");
    if (FILTERS.has(show)) view.runFilter = show;
    const project = params.get("project");
    if (project) view.projectFilter = project;
  }

  /** Keep the address bar in step, so the current view can be linked or kept. */
  function writeFiltersToUrl() {
    try {
      const url = new URL(window.location.href);
      if (view.runFilter === "all") {
        url.searchParams.delete("show");
      } else {
        url.searchParams.set("show", view.runFilter);
      }
      if (view.projectFilter === "all") {
        url.searchParams.delete("project");
      } else {
        url.searchParams.set("project", view.projectFilter);
      }
      if (url.href !== window.location.href) {
        window.history.replaceState(null, "", url);
      }
    } catch (error) {
      // A browser that refuses history is still a working page.
    }
  }

  function runMatchesFilters(run) {
    if (view.projectFilter !== "all" && run.cronjob !== view.projectFilter) return false;
    switch (view.runFilter) {
      case "active":
        return ACTIVE_STATES.has(run.state);
      case "failed":
        return run.state === "failed";
      case "succeeded":
        return run.state === "succeeded";
      default:
        return true;
    }
  }

  /* ------------------------------------------------------------------------
     The table
     ------------------------------------------------------------------------ */

  function runRow(run) {
    const summary = buildSummary(run);
    const actions = [
      h("button", {
        type: "button",
        class: "btn btn-quiet btn-sm",
        text: "Logs",
        onclick: () => openLogs(run),
      }),
    ];
    if (CONFIG.canMutate) {
      actions.push(
        h("button", {
          type: "button",
          class: "btn btn-quiet btn-sm",
          text: "Delete",
          title: "Delete this Job and its pod",
          onclick: () => confirmDelete(run),
        }),
      );
    }

    const stateParts = [stateLabel(run.state)];
    if (run.stateReason && run.stateReason !== "Active") {
      stateParts.push(h("span", { class: "state-reason", text: run.stateReason }));
    }
    if (run.stateMessage) {
      // Clamped to two lines by the stylesheet, so the full text - which for a
      // blocked run is the scheduler's whole explanation - goes in the title.
      stateParts.push(
        h("span", { class: "state-reason", text: run.stateMessage, title: run.stateMessage }),
      );
    }

    return h(
      "tr",
      {},
      h(
        "td",
        {},
        h("code", { class: "run-name", title: run.name, text: run.name }),
        h("span", {
          class: "run-sub",
          text: `${run.manual ? "manual" : "scheduled"}${summary ? ` · ${summary}` : ""}`,
        }),
      ),
      h(
        "td",
        { class: "run-project" },
        run.project || "—",
        run.cronjob && run.cronjob !== run.project ? h("code", { text: run.cronjob }) : null,
      ),
      h("td", { class: "cell-state" }, stateParts),
      h(
        "td",
        { class: "num cell-started", title: formatAbsolute(run.startTime || run.createdAt) },
        formatRelative(run.startTime || run.createdAt),
      ),
      h("td", { class: "num cell-took", text: formatDuration(run.durationSeconds) }),
      h("td", {}, h("div", { class: "cell-actions" }, actions)),
    );
  }

  function renderRuns(snapshot) {
    const rows = $("run-rows");
    const all = snapshot.runs || [];
    const shown = all.filter(runMatchesFilters);

    $("run-count").textContent = String(all.length);
    $("runs-hint").textContent =
      shown.length === all.length ? "" : `showing ${shown.length} of ${all.length}`;

    if (!shown.length) {
      const message = all.length
        ? "No run matches the filters above."
        : "No runs yet. Start one from the Build page.";
      fill(rows, h("tr", { class: "row-empty" }, h("td", { colspan: "6", text: message })));
      return;
    }

    fill(rows, shown.map(runRow));
  }

  function syncProjectFilter(snapshot) {
    const names = new Set();
    for (const run of snapshot.runs || []) {
      if (run.cronjob) names.add(run.cronjob);
    }
    if (view.projectFilter !== "all") names.add(view.projectFilter);

    const options = [h("option", { value: "all", text: "Any project" })];
    for (const name of [...names].sort()) {
      options.push(h("option", { value: name, text: name }));
    }
    const select = $("project-filter");
    fill(select, options);
    select.value = names.has(view.projectFilter) ? view.projectFilter : "all";
    view.projectFilter = select.value;
  }

  function render(snapshot) {
    syncProjectFilter(snapshot);
    renderRuns(snapshot);
    if (logs.job) refreshLogs({ silent: true });
  }

  /* ------------------------------------------------------------------------
     The log viewer
     ------------------------------------------------------------------------ */

  const logs = {
    job: null,
    container: "",
    follow: true,
    timer: null,
  };

  function containerChoices(run) {
    const choices = [];
    for (const name of run.initContainers || []) {
      choices.push({ name, kind: "init" });
    }
    for (const name of run.containers || []) {
      choices.push({ name, kind: "main" });
    }
    return choices;
  }

  function populateContainerSelect(run) {
    const select = $("logs-container");
    const choices = containerChoices(run);
    logs.container = run.defaultContainer || (choices.length ? choices[choices.length - 1].name : "");

    fill(
      select,
      choices.map((choice) =>
        h("option", {
          value: choice.name,
          text: choice.kind === "init" ? `${choice.name} (init)` : choice.name,
        }),
      ),
    );
    select.value = logs.container;
    select.disabled = choices.length < 2;
  }

  function logFollowLabel() {
    $("logs-follow").setAttribute("aria-pressed", String(logs.follow));
    $("logs-follow").textContent = logs.follow ? "Following" : "Follow";
  }

  function writeLogText(text) {
    const output = $("logs-output");
    const atBottom = output.scrollHeight - output.scrollTop - output.clientHeight < 40;
    const unchanged = output.textContent === text;
    if (!unchanged) output.textContent = text;
    if (logs.follow && (atBottom || unchanged)) {
      output.scrollTop = output.scrollHeight;
    }
  }

  async function refreshLogs({ silent = false } = {}) {
    if (!logs.job) return;
    const params = new URLSearchParams({ tail: String(CONFIG.logTail) });
    if (logs.container) params.set("container", logs.container);

    try {
      const data = await api(`/api/runs/${encodeURIComponent(logs.job)}/logs?${params.toString()}`);
      if (logs.job !== data.job) return; // the dialog moved on while we waited

      const body = data.logs || "";
      const note = data.note || "";
      writeLogText(body || note || "No output yet.");

      const metaParts = [];
      if (data.pod) metaParts.push(`pod ${data.pod}`);
      if (data.container) metaParts.push(`container ${data.container}`);
      if (note && body) metaParts.push(note);
      $("logs-meta").textContent = metaParts.join(" · ");
    } catch (error) {
      if (!silent) writeLogText(`Could not read the log: ${error.message}`);
      $("logs-meta").textContent = error.message;
    }
  }

  async function openLogs(run) {
    logs.job = run.name;
    logs.follow = true;
    logFollowLabel();
    $("logs-title").textContent = `Logs · ${run.project || run.name}`;
    $("logs-sub").textContent = run.name;
    $("logs-open").href = `/api/runs/${encodeURIComponent(run.name)}/logs?tail=${CONFIG.logTail}`;
    $("logs-open").hidden = false;
    $("logs-output").textContent = "loading…";

    populateContainerSelect(run);
    $("logs-dialog").showModal();
    await refreshLogs({ silent: false });

    if (logs.timer) clearInterval(logs.timer);
    logs.timer = setInterval(() => {
      if (!document.hidden) refreshLogs({ silent: true });
    }, 3000);
  }

  function closeLogs() {
    if (logs.timer) {
      clearInterval(logs.timer);
      logs.timer = null;
    }
    logs.job = null;
    logs.container = "";
    const dialog = $("logs-dialog");
    if (dialog.open) dialog.close();
  }

  /* ------------------------------------------------------------------------
     Confirmation and delete
     ------------------------------------------------------------------------ */

  let confirmHandler = null;

  function askConfirm(title, message, okLabel) {
    return new Promise((resolve) => {
      $("confirm-title").textContent = title;
      $("confirm-text").textContent = message;
      $("confirm-ok").textContent = okLabel;
      confirmHandler = resolve;
      $("confirm-dialog").showModal();
    });
  }

  function settleConfirm(answer) {
    const resolve = confirmHandler;
    confirmHandler = null;
    $("confirm-dialog").close();
    if (resolve) resolve(answer);
  }

  async function confirmDelete(run) {
    const agreed = await askConfirm(
      "Delete this run?",
      `Job ${run.name} and its pod are removed. A build that is still going is stopped, and the ` +
        "history for this run is gone. The image it was building is not affected.",
      "Delete run",
    );
    if (!agreed) return;
    try {
      await api(`/api/runs/${encodeURIComponent(run.name)}`, { method: "DELETE" });
      toast(`Deleted ${run.name}`, "success");
      if (logs.job === run.name) closeLogs();
      await refresh();
    } catch (error) {
      toast(`Could not delete the run: ${error.message}`, "error");
    }
  }

  /* ------------------------------------------------------------------------
     Wiring
     ------------------------------------------------------------------------ */

  function wire() {
    $("run-filter").addEventListener("change", (event) => {
      view.runFilter = event.target.value;
      writeFiltersToUrl();
      const snapshot = current();
      if (snapshot) renderRuns(snapshot);
    });

    $("project-filter").addEventListener("change", (event) => {
      view.projectFilter = event.target.value;
      writeFiltersToUrl();
      const snapshot = current();
      if (snapshot) renderRuns(snapshot);
    });

    $("logs-close").addEventListener("click", closeLogs);

    $("logs-container").addEventListener("change", (event) => {
      logs.container = event.target.value;
      $("logs-output").textContent = "loading…";
      refreshLogs({ silent: false });
    });

    $("logs-follow").addEventListener("click", () => {
      logs.follow = !logs.follow;
      logFollowLabel();
      if (logs.follow) {
        const output = $("logs-output");
        output.scrollTop = output.scrollHeight;
      }
    });

    $("logs-output").addEventListener("scroll", (event) => {
      const output = event.currentTarget;
      const atBottom = output.scrollHeight - output.scrollTop - output.clientHeight < 40;
      // Scrolling up is how a person says "stop moving the text".
      if (!atBottom && logs.follow) {
        logs.follow = false;
        logFollowLabel();
      }
    });

    $("confirm-cancel").addEventListener("click", () => settleConfirm(false));
    $("confirm-ok").addEventListener("click", () => settleConfirm(true));
    $("confirm-dialog").addEventListener("cancel", (event) => {
      event.preventDefault();
      settleConfirm(false);
    });
    $("confirm-dialog").addEventListener("click", (event) => {
      if (event.target === $("confirm-dialog")) settleConfirm(false);
    });

    $("logs-dialog").addEventListener("cancel", (event) => {
      event.preventDefault();
      closeLogs();
    });
    $("logs-dialog").addEventListener("click", (event) => {
      if (event.target === $("logs-dialog")) closeLogs();
    });
  }

  readFiltersFromUrl();
  $("run-filter").value = view.runFilter;
  logFollowLabel();
  wire();
  onSnapshot(render);
  start();
})();
