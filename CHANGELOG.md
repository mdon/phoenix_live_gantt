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

### Naming

CSS class prefix: `lg-`. JS hooks: `LgBarPopover`, `LgAutoScroll`.
Events dispatched: `lg:scroll-today`.
