# LiveGantt

A Phoenix LiveView Gantt chart component: horizontal bars on a time axis,
dependency arrows between them, sub-projects with roll-up bars, corner
badges, click-to-detail popovers, expand/collapse hierarchy, and a built-in
geometry audit.

The `gantt/1` component is **render-only**: you give it events with `start`/`end`
**dates** and it draws bars, columns, connectors, and frames. It has no concept
of durations, working hours, or scheduling. If your domain has *durations + an
order + sub-projects* but no dates, the optional `LiveGantt.Layout.sequential/2`
helper does that translation for you (sequential waterfall, sub-project span,
day-aligned min span) with a pluggable calendar callback — see
[Laying out from durations](#laying-out-from-durations).

## Installation

```elixir
def deps do
  [
    {:live_gantt, "~> 0.1"}
  ]
end
```

There are **three** wiring steps — deps, JS, and CSS. Skipping the CSS step is
the most common mistake; the chart renders but library-specific styling is
silently missing (see below).

### 1. JS hooks

The popover, fade-on-open, and auto-scroll-to-today behaviours need the JS
hooks. In your `app.js`:

```js
import "../../deps/live_gantt/priv/static/assets/live_gantt.js"

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { ...window.LiveGanttHooks, ...myHooks }
})
```

The bars render without the hooks, but clicking a bar/label won't open its
popover and the today-button / auto-scroll won't work.

### 2. CSS / Tailwind (required)

**LiveGantt ships no stylesheet.** Its visuals are Tailwind utility classes
that live inside the component's template (`.ex` source in `deps/live_gantt`).
Tailwind only emits CSS for classes it can *see*, so you must add the package
to your content sources, or library-specific classes (the sub-project
pattern-fill, `text-[0.6rem]` connector labels, non-working-day shading,
badge sizing, …) get purged and the chart looks subtly broken.

**Tailwind v4** — add an `@source` to your `app.css`:

```css
@import "tailwindcss";
@source "../../deps/live_gantt/lib";
```

**Tailwind v3** — add a glob to `content` in `tailwind.config.js`:

```js
module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/my_app_web/**/*.*ex",
    "../deps/live_gantt/lib/**/*.*ex"
  ]
}
```

LiveGantt uses **daisyUI** semantic color tokens (`bg-primary`,
`text-base-content`, `bg-success`, …). daisyUI isn't required — every color is
overridable per attr (see `bar_default_color_class` and friends) — but the
defaults assume those tokens resolve to something.

> Quick check that CSS is wired: a sub-project's roll-up bar should show a
> diagonal hatch pattern and connector labels should be legible. If bars are
> flat-colored and labels invisible, your content source is missing.

## Basic usage

```heex
<LiveGantt.gantt
  id="project"
  events={@tasks}
  date_range={@range}
  connectors={@connectors}
  zoom={:week}
  today={@today}
/>
```

A task is a `LiveGantt.Task` struct:

```elixir
%LiveGantt.Task{
  id: "cut-wood",                # unique within the chart; connectors + parent_id reference this
  title: "Cut planks to length",
  start: ~D[2026-04-01],
  end: ~D[2026-04-04],           # EXCLUSIVE — see "Dates → bars" below
  color: "bg-primary",
  assignee: "Sara",
  progress_pct: 60,
  extra: %{}                     # badges, actions, parent_id, per-task overrides
}
```

`date_range` is a `Date.Range` (`Date.range(first, last)`) for the visible
axis. Pass `id` whenever you use the built-in toolbar (`show_header`) or
auto-scroll, and always when more than one chart shares a page — DOM ids and
JS dispatches are namespaced by it.

See `LiveGantt.gantt/1` for the full attr list (there are many styling hooks,
all with sane defaults) and `LiveGantt.Task` for all task fields.

## Dates → bars

How a task's `start`/`end` become a bar — worth reading once, because `end`
being exclusive trips people up:

- **`end` is exclusive.** A bar covers `[start, end)`. A task that occupies
  just April 1 is `start: ~D[2026-04-01], end: ~D[2026-04-02]`. If `end` is
  `nil`, `LiveGantt.Task.effective_end/1` fills it in: `start + 1 day` for a
  `Date`, `+30 min` for a `DateTime`/`NaiveDateTime`.
- **Milestones.** When `end <= start` (zero duration) the task renders as a
  diamond instead of a bar. A `nil`-`end` task with **no children** is a
  milestone too.
- **Minimum width.** Single-day bars are clamped to 4px so they stay visible
  at `:month` zoom.
- **Out-of-range events are dropped, not clipped.** A task entirely outside
  `date_range` isn't rendered; instead it's counted into the
  "← N earlier / N later →" edge indicators. Wire `on_show_earlier` /
  `on_show_later` to let users widen the range.
- **Zoom** (`:day` / `:week` / `:month`) only changes column grouping and
  pixels-per-day; it never changes which events are in range.

## Sub-projects (hierarchy + roll-up)

Any event becomes a child of another by setting `extra.parent_id` to the
parent event's `id`. The parent renders as a **roll-up bar** spanning its
descendants, with an expand/collapse chevron and a framed band across both
columns.

Three things that aren't obvious and cost me time when I built the first
consumer — they're the rules to internalize:

1. **Always include every descendant in `events`.** The library decides an
   event is a sub-project (and draws the chevron) by finding other events that
   point at it via `parent_id`. It then hides the children of *collapsed*
   parents itself. So you emit the full tree every render and let `expanded`
   control visibility — do **not** add children only when expanded, or a
   collapsed parent has nothing pointing at it and never gets a chevron.

2. **Let the parent's dates roll up — pass `start: nil, end: nil`.** A
   sub-project parent with nil dates is auto-sized to span its descendants'
   min start / max end. If you instead give the parent explicit dates (e.g.
   from a rolled-up duration), the library uses *those* and the children can
   visually spill outside the bar — you'd have to size the parent to its
   children yourself. Nil-and-let-it-roll-up is almost always what you want.

3. **`on_toggle_expand` fires with the param key `event-id`** (hyphen, from
   `phx-value-event-id`), and you own the `expanded` set:

   ```elixir
   # render
   <LiveGantt.gantt
     events={@events}
     date_range={@range}
     expanded={@expanded}                 # MapSet | list | :all | nil
     on_toggle_expand="toggle_subproject"
   />

   # the handler — note the hyphenated key
   def handle_event("toggle_subproject", %{"event-id" => id}, socket) do
     expanded = socket.assigns.expanded
     expanded =
       if MapSet.member?(expanded, id),
         do: MapSet.delete(expanded, id),
         else: MapSet.put(expanded, id)

     {:noreply, assign(socket, expanded: expanded)}
   end
   ```

`expanded` accepts a `MapSet`, a plain list, `:all` (everything expanded), or
`nil` (all collapsed). Connectors that point at a hidden child are
automatically retargeted to its nearest visible ancestor, so arrows never
dangle.

## Laying out from durations

If your data has durations rather than dates, `LiveGantt.Layout.sequential/2`
turns it into the dates `gantt/1` wants — so you don't hand-roll (and re-bug)
the waterfall + sub-project-span + day-alignment yourself:

```elixir
layout =
  LiveGantt.Layout.sequential(tasks,
    start: ~D[2026-06-01],
    id: & &1.id,
    parent_id: & &1.parent_id,      # nil = top-level; others nest
    duration: & &1.hours,           # opaque — only your :advance interprets it
    order: & &1.position,
    advance: fn start_date, hours, task ->
      # your calendar: weekends, working hours, holidays — all live here
      MyApp.Calendar.add(start_date, hours, task)
    end
  )
# => %{id => %{start: ~D[...], end: ~D[...]}}

events =
  Enum.map(tasks, fn t ->
    %{start: s, end: e} = layout[t.id]
    %LiveGantt.Task{id: t.id, title: t.title, start: s, end: e,
                    extra: %{parent_id: t.parent_id}}
  end)
```

It works entirely in `Date`s, so each item gets at least a one-day slot
(`:min_span_days`, default 1), siblings never overlap, and a sub-project's bar
always spans its laid-out children. The business calendar is *yours* (the
`:advance` callback); the library stays domain-agnostic. It does **not** do
dependency-driven scheduling, critical path, or resource leveling — supply your
own dates for those.

## Connectors

Dependency arrows are plain maps referencing event ids:

```elixir
%{from: "cut-wood", to: "assemble", type: :fs, critical: true, label: "2d lag"}
```

- `type` — `:fs` (finish-to-start, default), `:ss`, `:ff`, `:sf`.
- A connector whose `from`/`to` isn't a visible event id is silently skipped
  (e.g. it points outside `date_range`).
- A **backward / impossible** schedule (the dependent is laid out earlier than
  the constraint allows) is auto-detected and drawn in the `invalid` style
  (dashed, error color) — a free correctness check on your date mapping.
- `critical: true` draws it in the critical style; `label` annotates the line.

## Debugging

- `mix live_gantt.dump` renders a chart from a fixture and prints parsed bar
  geometry — handy for checking positions without a browser.
- `LiveGantt.Inspector` parses rendered HTML into geometry, and
  `LiveGantt.TestHelpers` adds property assertions (bar containment, ordering,
  connector validity) you can use in your own tests.

## Gotchas

The short list of things that bite, collected from building the first
consumer:

- **No CSS content source** → chart renders but library-specific classes are
  purged. (See CSS step above — the #1 issue.)
- **`end` is exclusive** → a one-day task needs `end = start + 1`, not `end =
  start` (which is a milestone diamond).
- **Sub-project children must always be in `events`** → emit the full tree;
  `expanded` controls visibility. Adding children only when expanded breaks
  the chevron.
- **Give sub-project parents `nil` dates** → so they roll up to span their
  children. Explicit parent dates can let children spill outside the bar.
- **`on_toggle_expand` param is `"event-id"`** (hyphen), not `"event_id"`.
- **`id` is required** with `show_header` / auto-scroll, and whenever two
  charts share a page (ids + JS dispatches are namespaced by it).

## Status

Pre-1.0; API may shift. See CHANGELOG for breaking changes.

## License

MIT
