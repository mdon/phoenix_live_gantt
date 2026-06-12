# Changelog

## [0.1.0] — unreleased

Initial release. Extracted from `live_calendar`'s waterfall view into a
standalone package.

### Features

- `LiveGantt.gantt/1` component — horizontal bars on a time axis with
  orthogonal connector routing (FS/SS/FF/SF), bar-edge attach modes,
  bus stagger, smart trunk consolidation.
- `LiveGantt.Task` struct — Gantt-focused (no calendar/recurrence
  baggage).
- Sub-projects: any task with `extra.parent_id` becomes a child;
  parents roll up over descendants, expand/collapse via chevron or
  popover button, with framed timeline + sidebar treatment.
- Per-bar popover (click to open) with title, assignee/progress
  subtitle, optional custom action buttons (icon + tooltip +
  phx-click + per-event badges).
- Corner badges (notification-style pills with stacking + flash).
- Built-in `LiveGantt.Inspector` for HTML → geometry parsing and
  `LiveGantt.TestHelpers` for property assertions.
- `mix live_gantt.dump` for offline geometry inspection.
- JS hooks `LgBarPopover` + `LgAutoScroll`.

### Fixes

- Arrowheads into a milestone no longer detach from the shaft at a low fill
  factor. The head is nudged `@milestone_edge_px` (12px) out to the diamond's
  edge — a fixed SCREEN px — but it rides the connector's final approach segment,
  which was only `@elbow_px` (10px) of VIEWBOX. When the chart scrolls rather
  than fills (e.g. `:min5`, where that segment renders ~1:1), 12px of nudge
  overshot the 10px segment and the head floated off the trunk, disconnected. A
  milestone target now gets an approach stem a hair longer than the nudge
  (`@milestone_edge_px + 2`), so the head always lands ON the shaft at every
  zoom. (Connectors are still the normal horizontal zigzag — longer at a high
  fill is fine.)
- An open bar/label popover now sits above everything else in the chart
  (`z-[60]`). It was `z-40` — tying with milestone diamonds — and since rows are
  `position: relative` with no z-index (one shared stacking context), a popover
  that overhung the row below lost to that row's diamond by DOM paint order and
  got clipped. Clicking a milestone in a stack of same-date diamonds now shows an
  un-occluded popover. (Above bars z-10, today line z-30, diamonds z-40, and
  badges z-50.)
- Milestone diamonds are now clickable. They rendered with `cursor-pointer`
  (the default `milestone_class`) but carried no popover wiring — only the
  optional `on_event_click` — so a consumer that relied on the built-in popover
  (as bars do) got a diamond that looked clickable but did nothing. Diamonds now
  get the same `LgBarPopover` hook + popover sibling as bars, so clicking one
  opens its title/actions popover AND highlights its dependency tree (fading
  unrelated tasks) — the tool for tracing arrows through a cluster of
  same-date milestones. (The dependency highlight walks ancestors only, by
  design; an inline comment claiming it walked "both directions" was stale and
  has been corrected.)
- Column-header "today" highlight now honors the `today` attribute instead
  of always computing against `Date.utc_today()`, so it agrees with the
  today-marker line when a consumer passes an explicit `today`.
- The built-in toolbar's **Today** button is now disabled (with an
  explanatory tooltip) when it can't actually scroll — i.e. `enable_hooks`
  is off and no `on_scroll_today` is wired — instead of rendering enabled
  and silently doing nothing. (Default scroll-to-today needs `id` +
  `enable_hooks` so the `LgAutoScroll` hook has a target + listener.)
- Popover action buttons now always expose the event id as
  `phx-value-event-id` (hyphen), even when the action sets a `phx_value`
  map — previously a map made it `phx-value-event_id` (underscore),
  disagreeing with the no-value path and the chevron. Handlers now read
  `%{"event-id" => id}` consistently.
- `LgBarPopover` re-anchors a bar popover to the bar's CURRENT geometry on
  open, instead of trusting its (frozen, `phx-update="ignore"`) server-
  rendered position. Fixes popovers opening far from their bar after the
  chart re-rendered with new geometry — e.g. switching zoom.
- Connector arrowheads no longer distort under the responsive fill. They were
  SVG `<marker>`s inside the `preserveAspectRatio="none"` shaft SVG, so at high
  fill factors they stretched into thin, disconnected-looking triangles. They
  now render in a fixed-px overlay anchored by `%` to the shaft's true terminal
  point (`LiveGantt.PathFormat.terminal/1`), so the head stays on the shaft end
  even when `consolidate_piercing_trunks` re-routes a forward path to end at a
  different y (the old marker rode the path, the overlay must re-derive it).
  New `Inspector` arrowhead extraction + `TestHelpers.assert_arrowheads_at_path_ends/2`
  (wired into `find_geometry_issues/2`) lock the head-meets-shaft invariant.
- Sub-day tasks are no longer mis-routed as milestones. `milestone?/1` (connector
  routing) tested `Date.diff(end, start) <= 0`, so any task shorter than a full
  day — common at `:hour` zoom — started and ended on the same DATE and was
  treated as a zero-duration milestone, even though `bar_geometry/3` (which uses
  fractional days) rendered it as a thin bar. The router then applied milestone
  endpoint offsets + the 10px diamond gap and frequently mis-flagged the
  dependency as backward (dashed), so arrows routed to/from a phantom diamond and
  looked disconnected. `milestone?/1` now uses the same fractional-day duration
  test as `bar_geometry/3` (identical to the old behavior for pure-`Date` events).
- Arrow tips now land ON the target bar's edge (gap 0) instead of a 4px natural
  gap. Under the responsive fill the shaft SVG stretches with the bars, so a
  natural-px gap was magnified into a visible disconnect (4px → ~15px at a 3.8×
  fill); the fixed-px arrowhead overlay now supplies the visual separation, so
  arrows read as connected at any fill factor. (Milestone targets keep their
  diamond-clearance gap.)

### Features

- **`LiveGantt.scroll_to_start/2` — scroll the timeline back to its start.** A
  `Phoenix.LiveView.JS` command (composes with `JS.push/2`) that the
  `LgAutoScroll` hook consumes (`lg:scroll-start`) to scroll the chart to its
  leftmost column. Pair it with a "home"/"fit" button whose server handler
  refits the window — the server can't move the scroll, and the built-in
  scroll-to-today only fires when the today marker is in view, so a refit that
  doesn't include today would otherwise leave the timeline parked at a stale
  spot. A pending-flag in the hook makes the scroll authoritative across the
  refit patch even when it moves the today marker (which would otherwise
  re-center on today).
- **`window_start` / `window_end` attrs — sub-day positioning window.** The
  positioning axis is normally `date_range`'s whole-day, midnight-to-midnight
  span. A consumer can now override the ORIGIN and SPAN with a pair of
  `NaiveDateTime`s so the axis starts/ends partway through a day — e.g. ~1 column
  before the first task at `:hour`/`:min15`/`:min5` zoom, instead of a wall of
  empty pre-task columns from midnight. Positioning threads a `view = {origin,
  span_days}` (origin is the whole-day `range.first` Date in the default path, a
  `NaiveDateTime` when overridden) through bars, connector endpoints, the today
  marker, sub-project frames, obstacles, and a new `window_columns/5` column
  builder that walks fixed slot-minute steps from the origin (labels: the date on
  each midnight slot, a bare hour on `:hour`, the `:15` clock boundaries on
  sub-hour zooms). `date_range` still drives event partition / edge counts, so
  keep it covering the same window. Behavior is byte-identical when the override
  is absent (origin = `range.first`, span = `total_days`). Snap `window_start` to
  a slot boundary so column labels land on round clock times.
- **`tiny_bar_px` attr (default `5`) — "too small to see" marker.** A bar whose
  TRUE width renders narrower than this many SCREEN pixels gets a small
  fixed-size down-triangle at the task's start, signalling a task that's there
  but too short to see. The decision is **pure CSS** — each marker lives inside a
  per-task `container-type: inline-size` element whose width tracks the bar's
  rendered width, and an injected container query (`@container (max-width:
  {tiny_bar_px}px)`) reveals it. So it's server-emitted and browser-resolved
  against true screen pixels: correct under the responsive fill + zoom, **instant
  on first paint** (no socket/hook/measurement), and re-resolved on resize by the
  browser with zero JavaScript. The marker is clickable (opens the same popover —
  that part needs `enable_hooks`). Set `0` to disable. Pairs with `min_bar_px: 0`
  (the default) so bars stay honest while hairline tasks remain discoverable.
  Assumes a uniform `tiny_bar_px` across charts sharing a page.
- **`min_bar_px` attr (default `0`) — bars reflect their TRUE duration.**
  Previously every non-milestone bar was floored to a 4px minimum so a short
  task stayed a visible sliver. That made the bar overstate the task's span and
  diverge from the connector geometry (arrows attached to a phantom edge). The
  floor is now opt-in: by default a bar is exactly as wide as its duration (a
  task too short to show at the current zoom is a hairline / vanishes until you
  zoom in), so the chart is honest and connectors attach to the real edge. Set
  `min_bar_px` to e.g. `4` to restore the always-visible-sliver behavior. (A
  zero-DURATION task is still a milestone diamond regardless.) Connector endpoints
  are DRAWN from the RENDERED bar edges (so a non-zero `min_bar_px` stays
  consistent with where arrows attach), but the backward/invalid ("time-travel")
  decision is JUDGED from the NATURAL temporal edges — otherwise a zero-gap FS
  dependency (B starting exactly when A finishes) would be falsely flagged
  backward by A's min-width sliver poking past B's start.
- **`:hour` zoom + continuous coordinates.** The positioning axis is now a
  continuous "fractional days from range start" used uniformly by bars, the
  today marker, connector endpoints, and columns — so a `:hour` zoom (and
  DateTime/NaiveDateTime `start`/`end`) renders intra-day detail (a 2h and a 6h
  task differ in width/position). `Date` inputs at day/week/month zoom are
  byte-identical to before. `today` accepts a `DateTime`/`NaiveDateTime` for a
  precise "now" line + current-hour column highlight; positioning uses
  wall-clock time (DST-safe). `LiveGantt.Layout.sequential/2` gained a
  `:min_span` `{unit, n}` option and emits sub-day temporals when its
  `:start`/`:advance` do.
- **Responsive fit-to-width (pure CSS, no round-trip).** Horizontal geometry
  (bars, columns, today marker, sub-project frames, badges, popovers) now
  renders as PERCENTAGES of the content width, and the timeline uses
  `width: 100%; min-width: {content_px}px` inside `overflow-x-auto`. A short
  chart fills the container exactly (no gap); a long one scrolls at its natural
  density — instantly, on first paint, with zero measurement or server
  round-trip. The connector SHAFT SVG keeps a pixel viewBox but renders
  `width: 100%` with `preserveAspectRatio="none"` + `vector-effect="non-scaling-stroke"`,
  so the lines scale in lockstep with the bars and stay aligned at any width (the
  connector router is unchanged). Arrow**heads** are drawn in a SEPARATE,
  non-stretched overlay (positioned by `%` so the tip tracks the bar-aligned
  shaft end, but sized in fixed px so the triangle never distorts) — a stretched
  line is still a correct line, but a stretched triangle is not an arrowhead.
  `day_width_px` now sets the natural content width (scroll threshold /
  density); `default_day_width_px/1` exposes the per-zoom defaults.
- **Off-screen Today hint.** When `today` falls outside `date_range`, a
  directional pill (`← Today` / `Today →`) now pins to the edge pointing
  toward today, instead of the consumer having to widen the axis to keep the
  marker on screen. Optional `on_show_today` makes it clickable (e.g. to jump
  to today); otherwise it's informational. The vertical marker line still
  renders only when today is in range.

### Ergonomics & docs

- `LiveGantt.Layout.sequential/2` — optional, domain-agnostic helper that lays
  items with *durations + order + sub-projects* out into `start`/`end` dates
  (sequential waterfall, sub-project span, day-aligned `:min_span_days`) with a
  pluggable `:advance` calendar callback. Keeps `gantt/1` render-only while
  giving consumers the durations→dates layout they'd otherwise hand-roll. Does
  not do dependency-driven scheduling / critical path / resource leveling.
- `LiveGantt.toggle_expanded/2` — convenience for `on_toggle_expand` handlers
  (accepts a MapSet/list/nil, returns a MapSet).
- README rewritten with the steps/gotchas that bite first-time consumers: the
  required **Tailwind content source** (no stylesheet ships), `end` being
  **exclusive**, the **sub-project rules** (always include descendants; give
  parents `nil` dates so they roll up), and the `on_toggle_expand` `"event-id"`
  param key.
- `expanded` / `on_toggle_expand` now carry attr docs (the `:all` shortcut,
  the hyphenated param key).

### Naming

CSS class prefix: `lg-`. JS hooks: `LgBarPopover`, `LgAutoScroll`.
Events dispatched: `lg:scroll-today`.
