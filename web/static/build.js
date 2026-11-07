/* ==========================================================================
   The Build page: one card per CronJob, with the actions that belong to it.

   Everything here reads from the snapshot the shell hands over; the two write
   actions post to /api and then ask for a fresh snapshot rather than patching
   the card in place, so what is on screen is always something the cluster
   actually said.
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
    stateLabel,
    healthBadge,
    onSnapshot,
    refresh,
    start,
  } = window.App;

  function chip(label, value) {
    return h(
      "span",
      { class: "chip" },
      h("span", { class: "chip-key", text: label }),
      value instanceof Node ? value : h("code", { text: value }),
    );
  }

  /** The line under a card's title: why it is paused, or why the last run failed. */
  function projectNote(project) {
    if (project.suspend) {
      return "Schedule paused: nothing will start by itself until it is resumed.";
    }
    const latest = project.latestRun;
    if (latest && (latest.state === "blocked" || latest.state === "failed") && latest.stateMessage) {
      return latest.stateMessage;
    }
    return "";
  }

  function lastRunRow(latest) {
    if (!latest) return h("p", { class: "card-run", text: "never run" });
    return h(
      "p",
      { class: "card-run" },
      stateLabel(latest.state),
      h("span", { title: formatAbsolute(latest.createdAt), text: formatRelative(latest.createdAt) }),
      latest.durationSeconds !== null && latest.durationSeconds !== undefined
        ? h("span", { text: `· ${formatDuration(latest.durationSeconds)}` })
        : null,
      latest.manual ? h("span", { text: "· manual" }) : null,
    );
  }

  function projectCard(project) {
    const latest = project.latestRun;
    const schedule = project.schedule
      ? `${project.schedule}${project.timezone ? ` ${project.timezone}` : ""}`
      : "no schedule";

    const chips = [];
    if (project.family) chips.push(chip("family", project.family));
    chips.push(chip("schedule", schedule));
    if (project.parameters && project.parameters.PACKER_PROJECT) {
      chips.push(chip("path", project.parameters.PACKER_PROJECT));
    }
    if (project.parameters && project.parameters.PACKER_BUILD_ARGS) {
      chips.push(chip("args", project.parameters.PACKER_BUILD_ARGS));
    }
    // The Secret holding the variable files: the one thing that stops a build
    // before Packer even starts, so it belongs on the card.
    for (const secret of project.requiredSecrets || []) {
      chips.push(chip("secret", secret));
    }
    if (project.concurrencyPolicy === "Forbid" && project.activeRuns > 0) {
      chips.push(chip("note", "a run is in progress, a new one waits"));
    }

    const note = projectNote(project);
    const actions = [];

    if (CONFIG.canMutate) {
      actions.push(
        h("button", {
          type: "button",
          class: "btn btn-primary",
          text: latest && ACTIVE_STATES.has(latest.state) ? "Build again" : "Build now",
          title: "Start one run now, exactly as the schedule would",
          onclick: (event) => startBuild(project.name, event.currentTarget),
        }),
      );
      actions.push(
        h("button", {
          type: "button",
          class: "btn btn-quiet",
          text: project.suspend ? "Resume" : "Pause",
          title: project.suspend
            ? "Re-enable the schedule"
            : "Stop the schedule starting runs; a run already going continues",
          onclick: (event) => toggleSuspend(project, event.currentTarget),
        }),
      );
    }
    actions.push(
      h("a", {
        class: "btn btn-quiet",
        href: `/runs?project=${encodeURIComponent(project.name)}`,
        text: "Runs",
        title: "Show this project's runs",
      }),
    );

    return h(
      "article",
      { class: "project-card", dataset: { health: project.health, project: project.name } },
      h(
        "div",
        { class: "card-head" },
        h(
          "div",
          {},
          h("h3", { class: "card-title", text: project.project || project.name }),
          h("code", { class: "card-name", text: project.name }),
        ),
        healthBadge(project.health),
      ),
      project.purpose ? h("p", { class: "card-purpose", text: project.purpose }) : null,
      h("div", { class: "chips" }, chips),
      lastRunRow(latest),
      note ? h("p", { class: "card-note", text: note }) : null,
      h("div", { class: "card-actions" }, actions),
    );
  }

  /** Runs whose CronJob is gone: worth showing, impossible to start again. */
  function orphanCard(orphan) {
    return h(
      "article",
      { class: "project-card", dataset: { health: "orphan", project: orphan.name } },
      h(
        "div",
        { class: "card-head" },
        h(
          "div",
          {},
          h("h3", { class: "card-title", text: orphan.project || orphan.name }),
          h("code", { class: "card-name", text: orphan.name }),
        ),
        healthBadge("orphan"),
      ),
      h("p", {
        class: "card-purpose",
        text: "These runs belong to a CronJob that no longer exists, so they cannot be started again. Delete them from the Runs page when the history is no longer needed.",
      }),
      h("div", { class: "chips" }, chip("runs", String(orphan.runCount))),
      h(
        "div",
        { class: "card-actions" },
        h("a", {
          class: "btn btn-quiet",
          href: `/runs?project=${encodeURIComponent(orphan.name)}`,
          text: "Runs",
        }),
      ),
    );
  }

  function render(snapshot) {
    const host = $("project-grid");
    const projects = snapshot.projects || [];
    const orphans = snapshot.orphanProjects || [];

    $("project-count").textContent = String(projects.length);

    if (!projects.length && !orphans.length) {
      fill(
        host,
        h("p", {
          class: "muted",
          text:
            `No build CronJobs in namespace ${snapshot.namespace}. They come from ` +
            "the packer-imaging chart: kubernetes/charts/packer-imaging.",
        }),
      );
      return;
    }

    fill(host, projects.map(projectCard), orphans.map(orphanCard));
  }

  /* ------------------------------------------------------------------------
     Actions
     ------------------------------------------------------------------------ */

  async function startBuild(cronjobName, button) {
    if (!CONFIG.canMutate || !button) return;
    const label = button.textContent;
    button.disabled = true;
    button.textContent = "Starting…";
    try {
      const result = await api(`/api/projects/${encodeURIComponent(cronjobName)}/runs`, {
        method: "POST",
      });
      toast(result.message || "Build started", "success");
      await refresh();
    } catch (error) {
      toast(`Could not start the build: ${error.message}`, "error");
    } finally {
      // The card is rebuilt from the next snapshot, so this only matters when
      // the request failed and the card is still the same one.
      button.disabled = false;
      button.textContent = label;
    }
  }

  async function toggleSuspend(project, button) {
    if (!CONFIG.canMutate || !button) return;
    const next = !project.suspend;
    button.disabled = true;
    try {
      const result = await api(`/api/projects/${encodeURIComponent(project.name)}`, {
        method: "PATCH",
        body: JSON.stringify({ suspend: next }),
      });
      toast(result.message || "Schedule updated", "success");
      await refresh();
    } catch (error) {
      toast(`Could not change the schedule: ${error.message}`, "error");
      button.disabled = false;
    }
  }

  onSnapshot(render);
  start();
})();
