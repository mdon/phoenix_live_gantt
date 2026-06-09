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

### Features

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
- **Fit-to-width.** A `day_width_px` attr overrides the per-zoom density, and a
  `fit_width` flag makes the container report its available width
  (`"lg-fit-width"` event, `%{"available_px" => n}`, on mount + resize via the
  `LgAutoScroll` hook) so a consumer can size px-per-day to fill the viewport
  instead of leaving an empty gap after a short chart. `default_day_width_px/1`
  exposes the per-zoom defaults to use as the floor (fitting only ever widens;
  long charts keep their density and scroll).
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
