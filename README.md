# LiveGantt

A Phoenix LiveView Gantt chart component: horizontal bars on a time axis,
dependency arrows between them, sub-projects with roll-up bars, corner
badges, click-to-detail popovers, expand/collapse hierarchy, and a built-in
geometry audit.

## Installation

```elixir
def deps do
  [
    {:live_gantt, "~> 0.1"}
  ]
end
```

In your `app.js`:

```js
import "../../deps/live_gantt/priv/static/assets/live_gantt.js"

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { ...window.LiveGanttHooks, ...myHooks }
})
```

## Basic usage

```heex
<LiveGantt.gantt
  id="project"
  events={@tasks}
  date_range={@range}
  connectors={@connectors}
/>
```

A task is a `LiveGantt.Task` struct:

```elixir
%LiveGantt.Task{
  id: "cut-wood",
  title: "Cut planks to length",
  start: ~D[2026-04-01],
  end: ~D[2026-04-04],
  color: "bg-primary",
  assignee: "Sara",
  progress_pct: 60
}
```

Connectors are maps:

```elixir
%{from: "cut-wood", to: "assemble", type: :fs, critical: true}
```

See `LiveGantt.gantt/1` for the full attr list and `LiveGantt.Task` for
all task fields. See `Mix.Tasks.LiveGantt.Dump` for an offline debug tool.

## Status

Pre-1.0; API may shift. See CHANGELOG for breaking changes.

## License

MIT
