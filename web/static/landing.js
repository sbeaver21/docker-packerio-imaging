/* ==========================================================================
   The landing page: what state the namespace is in, at a glance.

   Deliberately read-only. It answers "is anything wrong" and "what happened
   recently", and hands you off to Build or Runs with a link that carries the
   filter you wanted, rather than offering the same controls on three pages.
   ========================================================================== */

"use strict";

(function () {
  const {
    h,
    fill,
    $,
    formatDuration,
    formatRelative,
    formatAbsolute,
    stateLabel,
    buildSummary,
    onSnapshot,
    start,
  } = window.App;

  /* ------------------------------------------------------------------------
     At a glance
     ------------------------------------------------------------------------ */

  function statCard(label, value, note) {
    return h(
      "div",
      { class: "stat-card" },
      h("p", { class: "stat-label", text: label }),
      h("p", { class: "stat-value", text: value }),
      note ? h("p", { class: "stat-note", text: note }) : null,
    );
  }

  function renderStats(snapshot) {
    const counts = snapshot.counts || {};
    fill(
      $("stat-grid"),
      statCard("Projects", String(counts.projects || 0), "build CronJobs defined"),
      statCard("Runs", String(counts.runs || 0), "Jobs kept by the TTL"),
      statCard("Active now", String(counts.active || 0), "running, queued or blocked"),
      statCard(
        "Cluster",
        snapshot.serverVersion || "unknown",
        `${snapshot.namespace} · read ${formatRelative(snapshot.generatedAt)}`,
      ),
    );
  }

  /* ------------------------------------------------------------------------
     Capacity
     ------------------------------------------------------------------------ */

  function renderCapacity(capacity) {
    const host = $("capacity-grid");
    const resources = (capacity && capacity.resources) || [];
    if (!resources.length) {
      fill(host, h("p", { class: "muted", text: "No ResourceQuota is defined for this namespace." }));
      return;
    }
    fill(
      host,
      resources.map((resource) => {
        const percent = resource.percent === null ? null : Math.max(0, Math.min(100, resource.percent));
        return h(
          "div",
          {
            class: "capacity-card",
            dataset: { saturated: String(Boolean(resource.saturated)) },
            title:
              percent === null
                ? `${resource.label}: ${resource.used} of ${resource.hard}`
                : `${resource.label}: ${resource.used} of ${resource.hard} (${percent}%)`,
          },
          h("p", { class: "capacity-label", text: resource.label }),
          h(
            "p",
            { class: "capacity-value" },
            h("span", { class: "capacity-used", text: resource.used }),
            h("span", { class: "capacity-hard", text: `/ ${resource.hard}` }),
          ),
          h(
            "div",
            { class: "capacity-track" },
            h("div", {
              class: "capacity-fill",
              style: `width:${percent === null ? 0 : percent}%`,
            }),
          ),
        );
      }),
    );
  }

  /* ------------------------------------------------------------------------
     Needs attention

     Three things earn a row: a schedule someone paused, a project whose last
     run failed, and a run the scheduler could not place. Everything else is
     ordinary and belongs on the pages that are about it.
     ------------------------------------------------------------------------ */

  function attentionItem(tone, title, detail, href, linkText) {
    return h(
      "div",
      { class: "attention-item", dataset: { tone } },
      h("span", { class: "attention-dot", "aria-hidden": "true" }),
      h(
        "div",
        { class: "attention-body" },
        h("p", { class: "attention-title", text: title }),
        detail ? h("p", { class: "attention-detail", text: detail }) : null,
      ),
      h("a", { class: "attention-link", href, text: linkText }),
    );
  }

  function renderAttention(snapshot) {
    const items = [];

    for (const project of snapshot.projects || []) {
      const name = project.project || project.name;
      if (project.suspend) {
        items.push(
          attentionItem(
            "warn",
            `${name} is paused`,
            "No run will start on its own until the schedule is resumed.",
            `/build#${encodeURIComponent(project.name)}`,
            "Open",
          ),
        );
        continue;
      }
      const latest = project.latestRun;
      if (latest && latest.state === "failed") {
        items.push(
          attentionItem(
            "bad",
            `${name} failed`,
            latest.stateMessage || "The last run did not finish.",
            `/runs?project=${encodeURIComponent(project.name)}&show=failed`,
            "Logs",
          ),
        );
      }
    }

    // Blocked runs can belong to a project that is otherwise healthy, so they
    // are listed on their own rather than through the project card.
    for (const run of snapshot.runs || []) {
      if (run.state !== "blocked") continue;
      items.push(
        attentionItem(
          "warn",
          `${run.project || run.name} is waiting for capacity`,
          run.stateMessage || "The scheduler will not place its pod.",
          `/runs?project=${encodeURIComponent(run.cronjob || "")}&show=active`,
          "Open",
        ),
      );
    }

    $("attention-count").textContent = String(items.length);

    if (!items.length) {
      fill(
        $("attention-list"),
        h("p", {
          class: "muted",
          text: "Nothing is paused, failing or waiting for a pod.",
        }),
      );
      return;
    }

    fill($("attention-list"), items);
  }

  /* ------------------------------------------------------------------------
     Latest runs
     ------------------------------------------------------------------------ */

  const RECENT_LIMIT = 5;

  function recentRow(run) {
    const summary = buildSummary(run);
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
      h("td", { class: "run-project", text: run.project || "—" }),
      h("td", { class: "cell-state" }, stateLabel(run.state)),
      h(
        "td",
        { class: "num cell-started", title: formatAbsolute(run.startTime || run.createdAt) },
        formatRelative(run.startTime || run.createdAt),
      ),
      h("td", { class: "num cell-took", text: formatDuration(run.durationSeconds) }),
    );
  }

  function renderRecent(snapshot) {
    const rows = $("recent-rows");
    const runs = (snapshot.runs || []).slice(0, RECENT_LIMIT);
    if (!runs.length) {
      fill(
        rows,
        h("tr", { class: "row-empty" }, h("td", { colspan: "5", text: "No runs yet." })),
      );
      return;
    }
    fill(rows, runs.map(recentRow));
  }

  /* ------------------------------------------------------------------------
     Draw
     ------------------------------------------------------------------------ */

  function render(snapshot) {
    renderStats(snapshot);
    renderCapacity(snapshot.capacity);
    renderAttention(snapshot);
    renderRecent(snapshot);
  }

  onSnapshot(render);
  start();
})();
