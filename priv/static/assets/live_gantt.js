/**
 * LiveGantt JS Hooks
 *
 * Optional but recommended JS hooks for the LiveGantt chart:
 *   - LgBarPopover    : click bar/label to open the detail popover,
 *                       fade non-tree tasks, slide bottom badges past
 *                       the popover, etc.
 *   - LgAutoScroll    : center the today marker horizontally when the
 *                       chart mounts, re-centre on `lg:scroll-today`.
 *
 * Usage in your app.js:
 *
 *   import "../../deps/live_gantt/priv/static/assets/live_gantt.js"
 *
 *   let liveSocket = new LiveSocket("/live", Socket, {
 *     hooks: { ...window.LiveGanttHooks, ...myHooks }
 *   })
 */

(function () {
  "use strict";

  window.LiveGanttHooks = window.LiveGanttHooks || {};

  window.LiveGanttHooks.LgAutoScroll = {
    mounted() {
      this._onScrollToday = () => this._scrollToToday(true);
      this.el.addEventListener("lg:scroll-today", this._onScrollToday);

      if (this.el.dataset.autoScrollToday === "true") {
        // Wait one frame so layout is settled before we measure.
        requestAnimationFrame(() => this._scrollToToday(false));
      }
    },
    destroyed() {
      this.el.removeEventListener("lg:scroll-today", this._onScrollToday);
    },
    updated() {
      // Re-scroll on LiveView patches that replace the today marker
      // (e.g. date range navigation moves the marker to a new x).
      // Only if the marker is present AND auto-scroll is still on.
      if (this.el.dataset.autoScrollToday === "true") {
        requestAnimationFrame(() => this._scrollToToday(false));
      }
    },
    _scrollToToday(smooth) {
      const marker = this.el.querySelector(".lg-today");
      if (!marker) return;

      const markerRect = marker.getBoundingClientRect();
      const containerRect = this.el.getBoundingClientRect();

      // Marker's x relative to the scrollable content (includes current scroll).
      const markerOffset =
        markerRect.left - containerRect.left + this.el.scrollLeft;

      // Exclude the sticky-ish label column from the visible timeline width
      // so "center" means center of the bar area, not center of the whole
      // viewport (which would land today too far right).
      const labelHeader = this.el.querySelector(".lg-label-header");
      const labelWidth = labelHeader ? labelHeader.offsetWidth : 0;

      const visibleTimelineWidth = this.el.clientWidth - labelWidth;
      const targetScroll =
        markerOffset - labelWidth - visibleTimelineWidth / 2;

      this.el.scrollTo({
        left: Math.max(0, targetScroll),
        behavior: smooth ? "smooth" : "auto",
      });
    },
  };

  // ============================================================
  // LgBarPopover — click bar to open a popover anchored to
  // the bar with full title + custom action buttons. Click anywhere
  // outside the popover (or on a different bar) to close.
  // ============================================================
  //
  // Wired automatically via `phx-hook` on bar elements that have
  // `event.extra.actions` configured. Each hooked bar carries a
  // `data-popover-target="<id>"` pointing to its sibling popover div
  // (rendered next to the bar so the bar's overflow-hidden doesn't
  // clip the popover).
  //
  // Touch devices: a normal `click` event fires on tap, so this hook
  // works for both desktop click and mobile tap with no special-case
  // pointer handling.
  window.LiveGanttHooks.LgBarPopover = {
    mounted() {
      this._onClick = (e) => {
        // Clicks inside the popover itself shouldn't toggle / close
        // (action button clicks bubble through and would otherwise
        // immediately close the popover they live in).
        const popover = this._popover();
        if (popover && popover.contains(e.target)) return;

        // Clicks on the sub-project expand/collapse chevron must
        // pass through to LiveView's phx-click. We do NOT toggle
        // the popover AND do NOT call stopPropagation, so the
        // chevron's `phx-click` fires normally.
        if (e.target.closest(".lg-subproject-chevron")) return;

        e.stopPropagation();
        this._toggle();
      };

      this.el.addEventListener("click", this._onClick);

      // Track this bar in the document-level registry so the global
      // outside-click handler can find every open popover and close
      // them in one pass.
      window.LiveGanttHooks.LgBarPopover._installGlobal();
      window.LiveGanttHooks.LgBarPopover._bars.add(this.el);
    },

    destroyed() {
      this.el.removeEventListener("click", this._onClick);
      window.LiveGanttHooks.LgBarPopover._bars.delete(this.el);
      this._close();
    },

    _popover() {
      const id = this.el.dataset.popoverTarget;
      return id ? document.getElementById(id) : null;
    },

    _isOpen() {
      const p = this._popover();
      return p && !p.classList.contains("hidden");
    },

    _open() {
      const p = this._popover();
      if (!p) return;
      window.LiveGanttHooks.LgBarPopover._closeAll();
      p.classList.remove("hidden");
      this.el.dataset.popoverOpen = "true";

      // Highlight the active task's dependency tree; fade everything else.
      // Walks the connector graph in BOTH directions from the active task,
      // so ancestors AND descendants stay full color.
      const eventId = this.el.dataset.eventId;
      if (eventId) {
        window.LiveGanttHooks.LgBarPopover._applyTreeFade(this.el, eventId);
      }

      // Push bottom-corner badges of the active task down so the
      // expanded popover doesn't sit on top of them. Measured AFTER
      // the popover becomes visible (`requestAnimationFrame` ensures
      // layout is settled), so we get the popover's actual height.
      requestAnimationFrame(() => {
        window.LiveGanttHooks.LgBarPopover._pushBottomBadges(this.el, p);
      });
    },

    _close() {
      const p = this._popover();
      if (!p) return;
      p.classList.add("hidden");
      delete this.el.dataset.popoverOpen;

      // Restore everything else.
      window.LiveGanttHooks.LgBarPopover._clearTreeFade(this.el);
      window.LiveGanttHooks.LgBarPopover._restoreBottomBadges(this.el);
    },

    _toggle() {
      this._isOpen() ? this._close() : this._open();
    },
  };

  // Document-wide outside-click + Escape handlers, installed once.
  // Tracks every mounted bar so a single listener handles all of
  // them (avoids registering N document listeners).
  window.LiveGanttHooks.LgBarPopover._bars = new Set();
  window.LiveGanttHooks.LgBarPopover._globalInstalled = false;

  window.LiveGanttHooks.LgBarPopover._installGlobal = function () {
    if (this._globalInstalled) return;
    this._globalInstalled = true;

    document.addEventListener("click", (e) => {
      this._bars.forEach((bar) => {
        if (bar.dataset.popoverOpen !== "true") return;

        const popoverId = bar.dataset.popoverTarget;
        const popover = popoverId ? document.getElementById(popoverId) : null;

        // Click inside this bar OR its popover is fine — keep open.
        if (bar.contains(e.target)) return;
        if (popover && popover.contains(e.target)) return;

        // Click landed elsewhere — close + restore the faded tree
        // and any shifted bottom badges.
        if (popover) popover.classList.add("hidden");
        delete bar.dataset.popoverOpen;
        this._clearTreeFade(bar);
        this._restoreBottomBadges(bar);
      });
    });

    document.addEventListener("keydown", (e) => {
      if (e.key !== "Escape") return;
      this._closeAll();
    });
  };

  window.LiveGanttHooks.LgBarPopover._closeAll = function () {
    this._bars.forEach((bar) => {
      if (bar.dataset.popoverOpen !== "true") return;
      const popoverId = bar.dataset.popoverTarget;
      const popover = popoverId ? document.getElementById(popoverId) : null;
      if (popover) popover.classList.add("hidden");
      delete bar.dataset.popoverOpen;
      this._clearTreeFade(bar);
      this._restoreBottomBadges(bar);
    });
  };

  // Walk the connector graph BACKWARD from `activeId` to collect every
  // task that's required to reach it — i.e., its transitive ancestors.
  // Descendants (things that depend on this task) are NOT included;
  // they aren't required for THIS task's completion.
  //
  // For tasks inside a sub-project we also walk the parent_id chain
  // and the parent sub-project's own incoming connectors. A nested
  // task implicitly inherits everything its container sub-project
  // depends on, so those should stay full color too.
  window.LiveGanttHooks.LgBarPopover._collectTree = function (chartEl, activeId) {
    // Reverse adjacency: for each task, who points INTO it.
    const reverse = new Map();
    chartEl.querySelectorAll("[data-from-id][data-to-id]").forEach((c) => {
      const f = c.dataset.fromId;
      const t = c.dataset.toId;
      if (!reverse.has(t)) reverse.set(t, new Set());
      reverse.get(t).add(f);
    });

    // Parent chain: each task → its parent_id (if any). Multiple DOM
    // nodes (bar + label + milestone) carry the same data-parent-id;
    // the Map dedupes them by event id.
    const parentOf = new Map();
    chartEl.querySelectorAll("[data-event-id][data-parent-id]").forEach((el) => {
      const id = el.dataset.eventId;
      const pid = el.dataset.parentId;
      if (id && pid) parentOf.set(id, pid);
    });

    const tree = new Set([activeId]);
    const queue = [activeId];
    while (queue.length) {
      const id = queue.shift();

      // Incoming connector edges (predecessors).
      const incoming = reverse.get(id);
      if (incoming) {
        incoming.forEach((from) => {
          if (!tree.has(from)) {
            tree.add(from);
            queue.push(from);
          }
        });
      }

      // Walk up parent_id — the sub-project containing this task
      // contributes its OWN required chain too.
      const parent = parentOf.get(id);
      if (parent && !tree.has(parent)) {
        tree.add(parent);
        queue.push(parent);
      }
    }
    return tree;
  };

  // Add `lg-faded` to every bar/label/connector NOT in the active
  // task's dependency tree. Scoped to the chart that contains the
  // active bar so multiple charts on one page don't interfere.
  window.LiveGanttHooks.LgBarPopover._applyTreeFade = function (activeEl, activeId) {
    const chartEl = activeEl.closest(".lg-wrap");
    if (!chartEl) return;

    const tree = this._collectTree(chartEl, activeId);

    // Pass 1: bars + labels + milestones + bar-badges (anything carrying
    // data-event-id). Build up the set of groups that have at least one
    // task in the tree so we know which group headers stay full color.
    const groupsInTree = new Set();
    chartEl.querySelectorAll("[data-event-id]").forEach((el) => {
      if (tree.has(el.dataset.eventId)) {
        if (el.dataset.group) groupsInTree.add(el.dataset.group);
      } else {
        el.classList.add("lg-faded");
      }
    });

    // Pass 2: group headers (label-side) + group spacers (timeline-side).
    // Fade if NO event in their group is in the tree.
    chartEl
      .querySelectorAll(".lg-group[data-group], .lg-group-spacer[data-group]")
      .forEach((el) => {
        if (!groupsInTree.has(el.dataset.group)) {
          el.classList.add("lg-faded");
        }
      });

    // Pass 3: connectors — keep only edges where BOTH endpoints are in
    // the tree.
    chartEl.querySelectorAll("[data-from-id][data-to-id]").forEach((c) => {
      const inTree = tree.has(c.dataset.fromId) && tree.has(c.dataset.toId);
      if (!inTree) {
        c.classList.add("lg-faded");
      }
    });

    // Pass 4: PIN the active task's elements (bar, label, badges) with
    // `lg-pinned` so they're guaranteed full color even if some
    // other rule later tries to dim them. The active task isn't faded
    // by pass 1 anyway, but pinning gives a hard guarantee.
    chartEl
      .querySelectorAll(`[data-event-id="${CSS.escape(activeId)}"]`)
      .forEach((el) => el.classList.add("lg-pinned"));
  };

  // Strip every `lg-faded` mark inside the chart that owns
  // `activeEl`. Called on popover close + before opening a different
  // popover (so transitions are clean).
  window.LiveGanttHooks.LgBarPopover._clearTreeFade = function (activeEl) {
    const chartEl = activeEl.closest(".lg-wrap");
    if (!chartEl) return;
    chartEl
      .querySelectorAll(".lg-faded")
      .forEach((el) => el.classList.remove("lg-faded"));
    chartEl
      .querySelectorAll(".lg-pinned")
      .forEach((el) => el.classList.remove("lg-pinned"));
  };

  // When the popover opens it can extend far below the bar
  // (title + subtitle + actions row). Any bottom-corner badge of
  // the active task would then sit inside the popover's visual
  // footprint and feel like it belongs to the popup, not the row
  // below it. Slide every bottom-corner badge down by exactly the
  // overflow amount so it lands clear of the open popover.
  window.LiveGanttHooks.LgBarPopover._pushBottomBadges = function (activeEl, popover) {
    const chartEl = activeEl.closest(".lg-wrap");
    if (!chartEl) return;

    const eventId = activeEl.dataset.eventId;
    if (!eventId) return;

    // How much the popover extends below the bar's row. Popover sits
    // at top: 4px in the row container; row height comes from the
    // badge's data-row-px (set at render time). Negative or zero
    // means the popover fits inside the row → no push needed.
    const popoverHeight = popover.offsetHeight;
    const popoverTop = 4; // matches `popover_top_inset` on the server

    chartEl
      .querySelectorAll(
        `[data-event-id="${CSS.escape(eventId)}"][data-badge-corner^="bottom_"]`,
      )
      .forEach((badge) => {
        const rowPx = parseInt(badge.dataset.rowPx || "40", 10);
        // The badge's natural bottom edge sits at `rowPx` (top: rowPx-16,
        // height: 16). Shift it so it lands just below the popover
        // bottom — `popoverTop + popoverHeight + small gap`.
        const targetTop = popoverTop + popoverHeight + 4;
        const naturalBottom = rowPx;
        const shift = Math.max(0, targetTop - naturalBottom);
        badge.style.transform = `translateY(${shift}px)`;
      });
  };

  // Reset transforms on bottom-corner badges so they slide back to
  // their natural position when the popover closes.
  window.LiveGanttHooks.LgBarPopover._restoreBottomBadges = function (activeEl) {
    const chartEl = activeEl.closest(".lg-wrap");
    if (!chartEl) return;

    chartEl
      .querySelectorAll('.lg-bar-badge[data-badge-corner^="bottom_"]')
      .forEach((badge) => {
        badge.style.transform = "";
      });
  };

  // Log initialization
  var hookCount = Object.keys(window.LiveGanttHooks).length;
  if (typeof console !== "undefined" && console.debug) {
    console.debug(
      "[LiveGantt] Initialized with " + hookCount + " hook(s):",
      Object.keys(window.LiveGanttHooks)
    );
  }
})();
