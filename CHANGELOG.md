# Changelog

## [0.3.0] — 2026-06-22

Followable connector routing for dense charts, a relocated Today badge, and
theme-aware sub-project frames.

### Added

- **Outer-gutter routing for long dependency skips.** When a forward arrow skips
  down a tight "staircase" of consecutive bars with no clear channel anywhere
  (e.g. a packed waterfall layout), the trunk now descends a clear column to the
  LEFT of the staircase and crosses straight to the target, instead of piercing
  or hugging an intervening task. It shares that descent with sibling arrows from
  the same source — each branches off toward its own target — so they read as one
  line rather than crossing strokes.

### Changed

- **Connector trunks keep real clearance from unrelated bars.** A forward trunk
  aims for a comfortable gap from any bar it crosses, tightening toward a 1px
  floor only when forced, and routes via a detour when no clear channel exists —
  instead of running flush along a bar's edge (where it reads as part of the bar)
  or straight through it.
- **The "Today" badge moved to the date-header row.** It sits flush on the marker
  line (no border seam) rather than at the top of the body, where it overlapped
  bars and too-small-task markers.
- **Sub-project frame colors are theme-aware.** The expanded-sub-project band now
  uses translucent daisyUI tints (`color-mix` + the `--color-*` vars) per nesting
  depth, so it adapts to light/dark themes and no longer washes out the label
  text — previously an opaque light hex that looked harsh on dark themes. Override
  `subproject_frame_color` with any CSS color to customize.

### Fixed

- **No dialyzer warning on the sub-project date roll-up.** The parent-span
  roll-up uses a map-update (`%{ev | ...}`) rather than a named struct-update that
  a generic `Enum.map` binding can't narrow to `Task` — a harmless but noisy
  success-typing note.

## [0.2.0] — 2026-06-22

Week/month axis legibility + a solid arrowhead.

### Changed

- **Week/month axis snaps to whole columns.** At `:week`/`:month` granularity the
  date axis now rounds OUTWARD to whole-week (Mon–Sun) / whole-month boundaries,
  so every column is a complete, boundary-aligned week/month instead of a ragged
  partial stub (e.g. a 2-day "Sat–Sun" sliver). Bars keep their true dates within
  the widened axis. Pass a tight, task-fitted range and the chart rounds it out on
  its own. Finer granularities are unaffected.
- **Week columns are labeled with their date span** ("Apr 27 – May 3", or
  "May 4 – 10" within a month) instead of the ISO ordinal ("W18") — a range reads
  without mapping a week number back to dates.

### Fixed

- **A week straddling New Year is one column, not two.** Week chunking now keys on
  the full ISO week (`:calendar.iso_week_number/1`) rather than `{calendar_year,
  week}`, so ISO week 53 (Mon 2026-12-28 → Sun 2027-01-03) no longer splits into
  two mislabeled stubs across the year boundary.
- **Connector arrowheads render solid.** The head no longer inherits the line's
  alpha (the default `text-base-content/50`), so the shaft can't show through a
  half-transparent triangle. The line stays subtle; only the head is made opaque,
  and it works for any custom connector color (e.g. `text-primary/30` → a subtle
  line with a solid `text-primary` head).

## [0.1.1] — 2026-06-13

Docs + accessibility. No API changes.

### Added

- Much-expanded README: "Making it interactive" (hooks, the built-in toolbar,
  the `on_*` callback table, and the `extra.actions` / `extra.badges` shapes),
  "Translations" (the chrome `translations` map vs. consumer-resolved content —
  works with gettext, Cldr, or a JSONB multilang column), "Live updates", and
  an "Accessibility" section. New Gotchas: nil/duplicate id raises, `today`
  defaults to UTC, and `window_start`/`window_end` is all-or-nothing.
- `:doc` for the `translations` attr.

### Accessibility

- Sub-project chevrons now expose `aria-expanded` (and an `aria-label`), so
  screen readers announce expand/collapse state.
- The decorative connector + arrowhead SVGs are `aria-hidden`, so a screen
  reader walks the bars rather than the path geometry.

## [0.1.0] — 2026-06-13

Initial release. Extracted from `live_calendar`'s waterfall view into a
standalone package.

### Features

- `PhoenixLiveGantt.gantt/1` component — horizontal bars on a time axis with
  orthogonal connector routing (FS/SS/FF/SF), bar-edge attach modes,
  bus stagger, smart trunk consolidation.
- `PhoenixLiveGantt.Task` struct — Gantt-focused (no calendar/recurrence
  baggage).
- Sub-projects: any task with `extra.parent_id` becomes a child;
  parents roll up over descendants, expand/collapse via chevron or
  popover button, with framed timeline + sidebar treatment.
- Per-bar popover (click to open) with title, assignee/progress
  subtitle, optional custom action buttons (icon + tooltip +
  phx-click + per-event badges).
- Corner badges (notification-style pills with stacking + flash).
- Built-in `PhoenixLiveGantt.Inspector` for HTML → geometry parsing and
  `PhoenixLiveGantt.TestHelpers` for property assertions.
- `mix phoenix_live_gantt.dump` for offline geometry inspection.
- JS hooks `LgBarPopover` + `LgAutoScroll`.
- **`PhoenixLiveGantt.scroll_to_start/2` — scroll the timeline back to its start.** A
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
  wall-clock time (DST-safe). `PhoenixLiveGantt.Layout.sequential/2` gained a
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

### Fixes

- Connectors to/from a task at the very edge of the window no longer clip off the
  chart. A task flush against the left/right edge had no room for its connector's
  exit/entry stub (it bulges ~`@elbow_px` past the bar), so the stub — and
  sometimes the arrowhead — drew past `content_width` and got clipped by the
  chart's `overflow-x-auto`. The time axis now reserves a fixed `@axis_pad_px`
  (16px) of horizontal breathing room on each side: every x coordinate shifts in
  by the pad, `content_width` grows by 2×, and transparent spacer columns hold
  the margin so bars still exactly cover their time columns. (Absolute %s move,
  but every layer shares the padded denominator, so alignment is unchanged.)
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
  point (`PhoenixLiveGantt.PathFormat.terminal/1`), so the head stays on the shaft end
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


### Ergonomics & docs

- `PhoenixLiveGantt.Layout.sequential/2` — optional, domain-agnostic helper that lays
  items with *durations + order + sub-projects* out into `start`/`end` dates
  (sequential waterfall, sub-project span, day-aligned `:min_span_days`) with a
  pluggable `:advance` calendar callback. Keeps `gantt/1` render-only while
  giving consumers the durations→dates layout they'd otherwise hand-roll. Does
  not do dependency-driven scheduling / critical path / resource leveling.
- `PhoenixLiveGantt.toggle_expanded/2` — convenience for `on_toggle_expand` handlers
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
