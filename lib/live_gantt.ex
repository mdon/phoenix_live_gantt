defmodule LiveGantt do
  @moduledoc """
  Waterfall (Gantt) view — horizontal bars on a date-range axis.

  Each item is rendered as a row with a horizontal bar whose left edge
  corresponds to its start date and width corresponds to its duration.
  Optionally draws SVG connector lines between dependent items using
  orthogonal (right-angle) routing — the industry-standard approach for
  Gantt dependency arrows.

  ## Features

  - Multi-zoom: `:day`, `:week`, `:month` granularity
  - Today marker (vertical line)
  - Non-working day shading via `day_markers`
  - Progress indicator (fill percentage via `extra.progress_pct`)
  - Milestones (zero-duration items rendered as diamonds)
  - Orthogonal dependency connectors with arrow heads
  - Grouping via `extra.group` field
  - Custom item rendering via `:item` slot

  ## Data mapping

  Waterfall uses the standard `LiveGantt.Task` struct:

  | Waterfall concept | Event field |
  |-------------------|------------|
  | Task name         | `title` |
  | Start date        | `start` (Date) |
  | End date          | `end` (Date, exclusive) |
  | Duration          | Computed from start/end |
  | Status/color      | `color`, `status` |
  | Progress          | `extra.progress_pct` (0–100) |
  | Group/phase       | `extra.group` or `category` |
  | Assignee          | `extra.assignee` |
  | Milestone         | When start == end (zero duration) |

  Connectors are passed separately as a list of
  `%{from: event_id, to: event_id}` maps.

  ## Coordinate system

  Everything is pixel-based against a fixed content width
  (`total_days × day_width_px + 2 × axis_pad`, where `axis_pad` is a fixed
  16px margin on each side that gives edge connectors room — see
  `axis_pad_px/0`). This keeps bar positions, grid columns, today marker, and
  connector arrows aligned no matter the flex context.
  """

  use Phoenix.Component

  alias LiveGantt.Utils.{I18n, Safe}
  alias LiveGantt.PathFormat
  alias Phoenix.LiveView.JS

  # Row heights in pixels (matches default row_height attr of "2.5rem" = 40px)
  @default_row_px 40
  @group_header_px 28
  # Horizontal breathing room (px) reserved on EACH side of the time axis so a
  # connector exiting/entering a task at the very edge of the window — its
  # exit/entry stub bulges ~@elbow_px past the bar — has somewhere to draw
  # instead of clipping off the chart edge. The whole px coordinate system is
  # shifted right by this (via `x_px` + `bar_geometry`), `content_width` grows by
  # 2×, and transparent spacer columns hold the margin so the grid stays aligned.
  @axis_pad_px 16
  # Connector routing — preferred elbow stem length.
  @elbow_px 10
  # Hard minimum stem visibility. The bus-preferred elbow is ≥ this, but
  # wide-ish gaps (but not wide enough for full elbow) clamp down here.
  @min_exit_stem_px 6
  # The arrow marker is 6px wide with refX=6, so its visible triangle
  # extends ~3.6px west and ~2.4px east of the path endpoint. The approach
  # needs room for BOTH the arrowhead's east extent AND a visible horizontal
  # segment in front of it, otherwise the arrow looks glued to the trunk.
  # 10px = ~6 west arrowhead + a few px line-only.
  @min_approach_px 10
  # Label rendering. Labels are rendered at text-[0.6rem] (~9.6px).
  # Average proportional glyph width at that size is ~5px; we use that
  # as the per-character estimate since SVG isn't measuring real fonts.
  # The label text carries a paint-order=stroke halo for contrast over
  # both bars and lines — no background rect, which would cut through
  # the line on either side of narrow words that don't fill the estimate.
  @label_char_px 5
  # Extra clearance around the label when choosing routing, so the label
  # has breathing room off each end of the segment it sits on.
  @label_clearance_px 10

  @doc """
  Toggles an id in an `expanded` set — convenience for `on_toggle_expand`
  handlers so consumers don't re-write the member?/put/delete boilerplate.

  Normalizes the first argument to a `MapSet` (accepts a `MapSet`, a list, or
  `nil`) and returns a `MapSet`. The id should be the value delivered to your
  handler under the `"event-id"` param key.

      def handle_event("toggle_subproject", %{"event-id" => id}, socket) do
        {:noreply, update(socket, :expanded, &LiveGantt.toggle_expanded(&1, id))}
      end
  """
  @spec toggle_expanded(MapSet.t() | list() | nil, term()) :: MapSet.t()
  def toggle_expanded(%MapSet{} = set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  def toggle_expanded(nil, id), do: MapSet.new([id])
  def toggle_expanded(list, id) when is_list(list), do: toggle_expanded(MapSet.new(list), id)

  @doc """
  A `Phoenix.LiveView.JS` command that scrolls a chart's timeline back to its
  start (leftmost column). Pair it with a "home"/"fit" button whose server
  handler refits the window — the server can't move the scroll, and the built-in
  scroll-to-today only fires when the today marker is in view, so a refit that
  doesn't include today would otherwise leave the timeline scrolled to a stale
  spot. Requires `enable_hooks` + the matching `id` (the `LgAutoScroll` hook
  listens for the dispatched `lg:scroll-start`).

      <button phx-click={
        JS.push("fit_project") |> LiveGantt.scroll_to_start("project-gantt-\#{@id}")
      }>Project</button>

  Composes with an existing `JS` command (e.g. a `JS.push/2`); pass it as the
  first argument, or omit it to start a fresh command.
  """
  @spec scroll_to_start(JS.t(), String.t()) :: JS.t()
  def scroll_to_start(js \\ %JS{}, id) when is_binary(id),
    do: JS.dispatch(js, "lg:scroll-start", to: "##{id}")

  @doc """
  Renders a Gantt / waterfall chart — horizontal task bars on a time axis with
  orthogonal dependency connectors, milestones, sub-projects, and a built-in
  popover.

  Pass a list of `LiveGantt.Task` structs as `events` and a `Date.Range` as
  `date_range`; everything else is optional. Each attribute below documents its
  own default and behavior. The smallest useful call:

      <LiveGantt.gantt events={@tasks} date_range={@range} />

  Note: no stylesheet ships — your app's Tailwind must scan this library as a
  content source (see the README), and the JS hooks (`priv/static/assets/
  live_gantt.js`) must be registered for the popover / scroll-to-today.
  """
  attr :events, :list, default: []
  attr :date_range, Date.Range, required: true

  attr :window_start, NaiveDateTime,
    default: nil,
    doc:
      "Optional sub-day positioning origin. When `window_start`/`window_end` are both `NaiveDateTime`s, the axis starts/ends at those exact instants instead of `date_range`'s midnight-to-midnight span — useful at `:hour`/`:min15`/`:min5` zoom to begin ~1 column before the first task rather than at midnight (a wall of empty pre-task columns). Snap `window_start` to a column-slot boundary so labels land on round clock times. `date_range` is still used for non-positioning concerns (event partition, edge counts), so keep it covering the same window."

  attr :window_end, NaiveDateTime,
    default: nil,
    doc: "Sub-day positioning end instant. See `window_start`."

  attr :zoom, :atom, default: :week
  attr :connectors, :list, default: []

  attr :day_markers, :list,
    default: [],
    doc:
      "Non-working / highlighted day ranges, shaded in the grid. Each is a `%{start_date: Date.t(), end_date: Date.t() | nil, available: boolean()}` (an `end_date` of `nil` means a single day; `available: false` shades it as non-working)."

  attr :day_width_px, :integer,
    default: nil,
    doc:
      "Override the per-zoom pixels-per-day. The natural content width is `total_days * day_width_px + 2 * axis_pad_px()` (the pad reserves room for edge connectors); that is the scroll `min-width`. The chart is responsive and fills wider containers on its own (horizontal coords are percentages), so use this only to tune density / the scroll threshold. `nil` uses the zoom default."

  attr :min_bar_px, :integer,
    default: 0,
    doc:
      "Minimum rendered width (px) for a non-milestone bar. Default `0` — bars reflect their TRUE duration, so a task too short to show at the current zoom is a hairline (or vanishes) until you zoom in. Set e.g. `4` to floor every bar to a visible/clickable sliver at the cost of overstating very short tasks' spans (connectors still attach to the rendered edge). A zero-DURATION task is always a milestone diamond regardless of this value."

  attr :today, :any,
    default: nil,
    doc:
      "Today's date (a `Date`), or a `DateTime`/`NaiveDateTime` for a precise 'now' line — recommended at `:hour` zoom, where the marker lands at the exact time and the current-hour column highlights. Defaults to `Date.utc_today()`."

  attr :row_height, :string, default: "2.5rem"
  attr :label_width, :string, default: "14rem"
  attr :on_event_click, :any, default: nil

  # Sub-project expand/collapse. An event becomes a sub-project by
  # carrying `extra.parent_id => "<other-event-id>"` — the parent
  # then renders as a roll-up bar spanning every descendant's date
  # range. ALWAYS include every descendant in `events`; the library
  # detects a sub-project by finding events that point at it, and
  # hides the children of collapsed parents itself. Give a sub-project
  # parent `start: nil, end: nil` so its dates roll up to span its
  # children (explicit parent dates are left as-is and children can
  # then visually overflow the bar).
  attr :expanded, :any,
    default: nil,
    doc:
      "Which sub-projects are expanded (children visible). A `MapSet` or list of expanded event ids, `:all` to expand everything, or `nil` for all collapsed. Collapsed parents' children are hidden and connectors retarget to the visible ancestor."

  attr :on_toggle_expand, :any,
    default: nil,
    doc:
      "phx-click event name fired when a sub-project chevron is toggled. The handler receives the event id under the `\"event-id\"` param key (hyphen). Update your `expanded` set in response — see `LiveGantt.toggle_expanded/2`."

  attr :show_progress, :boolean, default: true
  attr :show_today, :boolean, default: true

  attr :show_today_edge, :boolean,
    default: true,
    doc:
      "Show the floating directional `← Today` / `Today →` pill when today is off-screen. Independent of `show_today` (which controls the in-range today line), so you can keep the line but drop the off-screen hint."

  attr :show_connectors, :boolean, default: true

  attr :tiny_bar_px, :integer,
    default: 5,
    doc:
      "When a bar renders narrower than this many SCREEN pixels, a small fixed-size down-triangle marker appears at the task's start to signal a too-small-to-see task. The decision is pure CSS — a container query against the bar's rendered width — so it's server-emitted, correct against the responsive fill + zoom, instant on first paint, and re-resolves on resize with no JavaScript. (Clicking the marker opens the same popover, which does need `enable_hooks`.) Set `0` to disable. Bars themselves stay at their true width — see `min_bar_px`. Assumes a uniform value across charts sharing a page."

  attr :avoid_collisions, :boolean,
    default: true,
    doc:
      "When true, connector trunks are shifted to avoid crossing unrelated bars. Turn off for very large Gantts or when you prefer strict bus alignment."

  attr :label_background, :atom,
    default: :halo,
    values: [:halo, :rect],
    doc:
      "How connector labels render. :halo (default) paints each glyph with a base-100 outline so the line shows between letters. :rect draws a solid base-100 rectangle behind the text — stronger contrast over bars but can leave visible gaps in the line around narrow words."

  # --- Connector styling defaults ---
  #
  # Per-connector fields on the connector map override these when set.
  # Color classes use Tailwind's `text-*` tokens (e.g. `text-success`);
  # the SVG paths use `stroke-current` and markers use `fill="currentColor"`
  # so a single color class drives both the line and its arrowhead.

  attr :connector_color_class, :string, default: "text-base-content/50"
  attr :connector_stroke_width, :float, default: 1.5
  attr :connector_opacity, :float, default: 1.0
  attr :connector_dasharray, :string, default: "none"

  attr :critical_color_class, :string, default: "text-primary"
  attr :critical_stroke_width, :float, default: 2.25

  attr :invalid_color_class, :string, default: "text-error"
  attr :invalid_stroke_width, :float, default: 2.0
  attr :invalid_dasharray, :string, default: "4 3"

  # --- Connector routing defaults ---
  attr :connector_elbow_px, :integer, default: 10
  attr :connector_bar_clearance_px, :integer, default: 10

  attr :bus_split_offset_pct, :integer,
    default: 40,
    doc:
      "Used by `bus_attach_mode={:type_zoned}`. When a bar side has both incoming and outgoing arrows, this is the % offset from the bar's top edge for outgoing attachment (incoming mirrors). Default 40 → 40%/60% split. Set to 50 to disable the split."

  attr :bus_attach_mode, :atom,
    default: :smart,
    values: [:smart, :type_zoned, :center],
    doc: """
    How arrow endpoints attach to a bar edge when multiple arrows touch it:
      * `:smart` (default) — each arrow's attach y depends on the OTHER end's row.
        Outgoing arrows going DOWN attach to the bar bottom; outgoing arrows going UP
        attach to the bar top. Incoming arrows from ABOVE land on the upper-middle of
        the bar; from BELOW land on the lower-middle. Up to 4 designated y positions
        per side. If only one of these positions is in use → collapses to bar center.
      * `:type_zoned` — outgoing always at top, incoming always at bottom (regardless
        of direction). Uses `bus_split_offset_pct`.
      * `:center` — disable splits entirely; everything attaches at the bar center.
    Per-task override: set `extra.bus_attach_mode` on an event to one of these atoms.
    """

  attr :bus_attach_inner_pct, :integer,
    default: 40,
    doc:
      "Smart mode only. % offset from bar edge for both attach positions. Default 40 → split at 40%/60% of bar height. Smart mode picks one for outgoing (by majority outgoing direction) and the opposite for incoming."

  attr :bus_stagger_outgoing_px, :integer,
    default: 0,
    doc:
      "Stagger trunk x by this many px per lane for arrows in the SAME outgoing bus (multiple outgoing from one source on one side). Default 0 = merged (single trunk). Set to 3-5 to fan out each outgoing arrow into its own visible lane. Per-task override via `extra.bus_stagger_outgoing_px`."

  attr :bus_stagger_incoming_px, :integer,
    default: 0,
    doc:
      "Stagger trunk x by this many px per lane for arrows in the SAME incoming bus (multiple incoming to one target on one side). Default 0 = merged. Per-task override via `extra.bus_stagger_incoming_px`."

  attr :bus_stagger_corner_clearance_px, :integer,
    default: 4,
    doc:
      "When stagger is active and a bar side has multiple arrows, lanes are distributed evenly across the bar's FLAT region (excluding rounded corners) so no arrow emerges from a corner. This sets the corner radius to avoid; default 4 matches Tailwind's `rounded` (4px) on the default `bar_class`. Set to 0 if your bar isn't rounded."

  # --- Task/bar styling defaults ---
  #
  # Each of these stacks onto a stable structural class (e.g. the
  # `lg-bar` marker is always present for CSS hooks and
  # tests). Consumers can replace the styling portion without losing
  # the marker. Defaults mirror the current hardcoded behaviour —
  # overriding with nil or a custom class lets you fully restyle.

  # Main column + label header
  # NOTE: the bottom border + background live on the label-header and the time
  # wrapper (below), NOT here — the sticky header is only as wide as the viewport,
  # so a border on it stops at the scroll edge and vanishes under columns scrolled
  # into view. The label-header + time wrapper always span the full content width.
  attr :main_header_class, :string, default: "flex sticky top-0 z-20"

  attr :label_header_class, :string,
    default:
      "flex-shrink-0 bg-base-100 border-r border-base-content/10 border-b-2 border-b-base-content/15 px-3 py-2 font-semibold text-sm text-base-content"

  attr :column_header_class, :string,
    default: "text-xs text-center py-2 border-r border-base-content/5 font-medium flex-shrink-0"

  attr :column_header_today_class, :string, default: "bg-primary/10 font-bold text-primary"

  # Grid dividers + non-working days
  attr :column_divider_class, :string,
    default: "border-r border-base-content/5 h-full flex-shrink-0"

  attr :non_working_class, :string, default: "bg-base-content/[0.04]"

  # Bar row (the horizontal row in the timeline)
  attr :row_class, :string,
    default: "relative border-b border-base-content/5 hover:bg-base-content/[0.02]"

  # Label column (left-side row holding the item's label)
  attr :label_col_class, :string,
    default: "relative flex-shrink-0 border-r border-base-content/10"

  attr :label_row_class, :string,
    default:
      "flex items-center px-3 border-b border-base-content/5 overflow-hidden cursor-pointer hover:bg-base-content/[0.02]"

  # Group header (both in the label column and as a spacer in the timeline)
  attr :group_header_class, :string,
    default: "flex items-center bg-base-200/50 border-b border-base-content/10 px-3"

  attr :group_header_text_class, :string,
    default: "text-xs font-bold uppercase tracking-wider text-base-content/60 truncate"

  attr :group_spacer_class, :string,
    default: "bg-base-200/50 border-b border-base-content/10 relative"

  # Bar (non-milestone events)
  attr :bar_class, :string,
    default:
      "absolute top-1 bottom-1 rounded cursor-pointer overflow-hidden flex items-center z-10"

  # Applied (additionally) when an event is a sub-project (has
  # children). Pattern fill differentiates the roll-up bar from
  # leaf-task bars without changing color or geometry — consumers
  # still get their `event.color` underneath. Brackets at the bar's
  # ends are added via gradient/border-style overlays.
  attr :bar_subproject_class, :string,
    default:
      "ring-1 ring-base-content/30 ring-offset-0 [background-image:repeating-linear-gradient(135deg,transparent_0_6px,rgba(0,0,0,0.08)_6px_7px)]"

  # SOLID inline `background-color`s applied to:
  #   1. the rectangle in the timeline column behind each EXPANDED
  #      sub-project's contents, and
  #   2. the sidebar label rows for those same events
  # so the sub-project reads as a single colored band across both
  # columns. Pass a LIST of colors and the renderer picks one per
  # nesting depth (top-level parent = index 0, first nested parent
  # = index 1, etc.) so a sub-project inside another sub-project
  # gets a visually distinct color instead of two translucent
  # layers stacking up to an unexpected hue. A single string is
  # accepted for backwards-compat and used at every depth.
  attr :subproject_frame_color, :any, default: ["#FEF3C7", "#DBEAFE", "#E0E7FF", "#FCE7F3"]

  attr :bar_background_class, :string, default: "absolute inset-0 rounded"
  attr :bar_default_color_class, :string, default: "bg-primary"

  attr :bar_title_class, :string, default: "relative z-10 text-xs font-medium truncate px-2"
  attr :bar_title_cancelled_class, :string, default: "line-through"

  # Progress fill on the bar
  attr :progress_class, :string, default: "absolute inset-y-0 left-0 rounded-l"
  attr :progress_complete_radius_class, :string, default: "rounded-r"
  attr :progress_incomplete_class, :string, default: "bg-base-content/20"
  attr :progress_complete_class, :string, default: "bg-success/40"

  # Milestone (zero-duration events, rendered as rotated square)
  attr :milestone_class, :string, default: "absolute top-1/2 z-40 cursor-pointer w-4 h-4 border-2"

  attr :milestone_default_color_class, :string, default: "bg-primary"
  attr :milestone_status_cancelled_class, :string, default: "opacity-50"

  # Status modifiers applied to bar backgrounds (not milestones)
  attr :status_tentative_class, :string, default: "opacity-60"
  attr :status_cancelled_class, :string, default: "opacity-40"
  attr :status_pending_approval_class, :string, default: "animate-pulse"
  attr :status_no_show_class, :string, default: nil
  attr :status_blocked_class, :string, default: "opacity-60 grayscale"

  # Bar popover (shown on bar click for every bar — carries the full
  # title, plus an optional second row of custom action buttons when
  # `event.extra.actions` is non-empty). The popover anchors to the
  # bar's left edge with `min-width: bar.width_px`, so it visually
  # extends the bar rather than floating separately.
  #
  # Click anywhere outside the popover or its bar closes it (or
  # Escape). Requires the `LgBarPopover` JS hook (auto-
  # registered with the rest of the LiveGantt hooks). Action map
  # shape: `%{icon, tooltip, phx_click, phx_value, phx_target, href,
  # label, class, id}`.
  # `z-[60]` puts an open popover above EVERYTHING else in the chart — bars
  # (z-10), the today line (z-30), milestone diamonds (z-40), and badges (z-50).
  # All those share one stacking context (rows are `position: relative` with no
  # z-index, so they don't make their own), so a popover tying at z-40 with the
  # diamonds would lose to a later row's diamond by DOM order and get clipped
  # where it overhangs the row below. The popover is the focused element; it wins.
  attr :bar_popover_class, :string,
    default:
      "absolute z-[60] max-w-md rounded-md shadow-lg border-2 border-base-content overflow-hidden hidden"

  # Title row: matches the bar's vertical metrics (height + 4px inset
  # via top-1 bottom-1 + center alignment) so the title's apparent
  # position doesn't jump when the popover opens. Padding mirrors the
  # bar title's px-2.
  attr :bar_popover_title_class, :string,
    default:
      "flex items-center px-2 text-xs font-medium whitespace-normal break-words leading-tight"

  # Subtitle row (below title): renders when the event has an
  # assignee and/or non-zero progress. Smaller + slightly muted vs.
  # title. Inherits color/text from the popover wrapper so it stays
  # readable on any bar color.
  attr :bar_popover_subtitle_class, :string,
    default: "px-2 pb-1 text-[0.65rem] opacity-80 leading-tight"

  # Actions row picks up the same color + status as the title so the
  # popover reads as one continuous extension of the bar. No top
  # divider — the colored wrapper already runs edge to edge.
  attr :bar_popover_actions_class, :string, default: "flex gap-1 px-2 py-2"

  # Buttons inherit color/text from the popover wrapper. Hover uses a
  # translucent overlay so it works against any bar color.
  attr :bar_action_button_class, :string,
    default:
      "relative inline-flex items-center justify-center w-7 h-7 rounded hover:bg-base-content/15 cursor-pointer"

  # Applied (additionally) when an action carries `disabled: true`.
  # Removes pointer cues + dims the button so it visually reads as
  # non-interactive. Pointer-events-none ensures the click never
  # fires regardless of the underlying element type.
  attr :bar_action_disabled_class, :string,
    default: "opacity-50 cursor-not-allowed pointer-events-none"

  # Label popover (same shape + behavior as bar popover but anchored
  # to the left label column). Click anywhere outside closes it; only
  # one popover (label or bar, anywhere in the chart) is open at a
  # time. Defaults extend slightly past the label column so the
  # popover visually breaks out into the timeline area.
  attr :label_popover_class, :string,
    default:
      "absolute left-2 right-2 z-[60] rounded-md shadow-lg border-2 border-base-content overflow-hidden hidden"

  # Badges (notification-style numbers/text in corners of bars + action
  # buttons). Per-event badges live on `event.extra.badges` (a list of
  # maps); per-action badges on `action.badge` (single map) or
  # `action.badges` (list). Each badge map:
  #
  #   %{
  #     content:    "5",            # required, text/number to display
  #     corner:     :top_right,     # :top_right | :top_left |
  #                                 # :bottom_right | :bottom_left
  #     color:      "bg-error",     # background, default bg-error
  #     text_color: "text-white",   # optional, default infers from color
  #     flash:      true,           # animate-pulse when truthy
  #     class:      "..."           # extra classes
  #   }
  #
  # Bars: badges render as siblings (so the bar's overflow-hidden
  # doesn't clip them). Action buttons: badges render inside the
  # button itself (button gains `relative` so absolute children
  # anchor correctly).
  attr :badge_class, :string,
    default:
      "absolute z-50 inline-flex items-center justify-center px-1 min-w-[1rem] h-4 text-[0.55rem] font-bold rounded-full ring-1 ring-base-100 leading-none pointer-events-none"

  attr :badge_default_color_class, :string, default: "bg-error"

  # Today marker (vertical line + badge on top)
  attr :today_marker_line_class, :string,
    default: "absolute top-0 w-0.5 bg-error z-30 pointer-events-none"

  attr :today_marker_badge_class, :string,
    default:
      "absolute top-0 -translate-x-1/2 bg-error text-error-content text-[0.55rem] px-1 rounded-b font-bold whitespace-nowrap"

  attr :translations, :map, default: %{}
  attr :class, :string, default: ""
  attr :dir, :atom, default: :ltr

  # --- Built-in toolbar (optional) ---
  #
  # When `show_header` is true the component renders its own toolbar with
  # zoom switcher, today button, and prev/next navigation. Consumers opt in
  # selectively via `show_zoom_switcher` / `show_today_button` /
  # `show_navigation`, and wire button clicks via the `on_zoom_change` and
  # `on_navigate` callbacks (JS-struct or string event-name, same pattern as
  # `on_event_click`). The today button fires a client-side `lg:scroll-
  # today` dispatch consumed by the `LgAutoScroll` hook; consumers
  # needing server-side behaviour can override with `on_scroll_today`.

  attr :id, :string,
    default: nil,
    doc:
      "Stable DOM id. Required when `show_header` is true OR `auto_scroll_today` is on, so JS dispatches target the right gantt instance when multiple are on the page."

  attr :show_header, :boolean, default: false
  attr :show_zoom_switcher, :boolean, default: true
  attr :show_today_button, :boolean, default: true
  attr :show_navigation, :boolean, default: true
  attr :zooms, :list, default: [:day, :week, :month]
  attr :on_zoom_change, :any, default: nil

  attr :on_navigate, :any, default: nil
  attr :on_scroll_today, :any, default: nil

  attr :toolbar_class, :string,
    default:
      "lg-toolbar flex items-center justify-between gap-3 px-3 py-2 border-b border-base-content/15 bg-base-100"

  # --- Edge indicators (out-of-range event counts) ---
  attr :show_edge_indicators, :boolean, default: true
  attr :on_show_earlier, :any, default: nil
  attr :on_show_later, :any, default: nil

  attr :on_show_today, :any,
    default: nil,
    doc:
      "phx-click event for the off-screen Today hint (shown when `today` is outside `date_range`). Wire it to widen the range / jump to today; if nil the hint is informational only. Requires `show_today`."

  attr :edge_indicator_class, :string,
    default:
      "lg-edge px-2 py-1 rounded-full bg-base-200/95 border border-base-content/10 text-[0.65rem] font-medium text-base-content/70 shadow-sm hover:bg-base-200 transition-colors"

  # --- JS hooks ---
  attr :enable_hooks, :boolean,
    default: false,
    doc:
      "When true, attaches BOTH JS hooks: `LgAutoScroll` on the container (auto-scroll + today button) and `LgBarPopover` on every bar/milestone/label (the click popover + dependency-tree highlight). Requires the LiveGantt JS bundle (`priv/static/assets/live_gantt.js`, registered as `window.LiveGanttHooks`). Leave false if you don't ship the bundle — otherwise the browser logs an \"unknown hook\" error per element."

  attr :auto_scroll_today, :boolean,
    default: true,
    doc:
      "On mount, scroll the timeline so today is horizontally centered (if today is in range and hooks are enabled)."

  slot :item
  slot :label

  slot :toolbar_start,
    doc: "Extra content rendered at the left of the toolbar, after the today/nav buttons."

  slot :toolbar_end,
    doc: "Extra content rendered at the right of the toolbar, after the zoom switcher."

  def gantt(assigns) do
    validate_event_ids!(assigns.events)

    today = assigns.today || Date.utc_today()
    range = assigns.date_range
    total_days = Date.diff(range.last, range.first) + 1

    # `day_width_px` overrides the per-zoom default — e.g. a consumer doing
    # fit-to-width passes a px-per-day computed from the measured viewport.
    day_px = assigns.day_width_px || day_width_px(assigns.zoom)
    row_px = parse_row_height(assigns.row_height)
    min_bar_px = assigns.min_bar_px

    # The POSITIONING window. Normally the whole-day `date_range` (origin =
    # `range.first` midnight, span = `total_days`). A consumer can override with
    # a sub-day `window_start`/`window_end` (NaiveDateTime) so the axis starts
    # partway through a day — e.g. ~1 column before the first task at `:hour`/
    # `:min15`/`:min5` zoom, instead of a wall of empty pre-task columns from
    # midnight. `view = {origin, span_days}` threads both through positioning.
    {origin, span_days} =
      case {assigns.window_start, assigns.window_end} do
        {%NaiveDateTime{} = ws, %NaiveDateTime{} = we} ->
          span = NaiveDateTime.diff(we, ws, :second) / 86_400
          # A non-positive window is meaningless — ignore the override and fall
          # back to the whole-day range rather than producing a 0/negative axis
          # (which flags every bar out-of-range and blanks/crashes the chart).
          if span > 0, do: {ws, span}, else: {range.first, total_days * 1.0}

        _ ->
          {range.first, total_days * 1.0}
      end

    view = {origin, span_days}
    content_width = round(span_days * day_px) + 2 * @axis_pad_px

    # Build column headers. Thread the resolved `today` (the explicit
    # `today` attr, else `Date.utc_today()`) so the column highlight
    # agrees with the today-marker line — both must use the same notion
    # of "today" or a consumer-supplied `today` highlights nothing.
    granularity = column_zoom_for(day_px, ceil(span_days))

    # A sub-day window (NaiveDateTime origin) MUST build its headers from the
    # window too, or they disagree with the window-positioned bars. Always take
    # the window-column path when the origin is intra-day — using the
    # granularity's slot, or falling back to hourly slots if the column budget
    # demoted the granularity below sub-day (a wide sub-day window). Only a
    # whole-day `Date` origin uses the date-range column builders.
    columns =
      case origin do
        %NaiveDateTime{} ->
          slot = if granularity in [:hour, :min15, :min5], do: slot_minutes(granularity), else: 60
          window_columns(origin, span_days, day_px, slot, today, assigns.translations)

        _ ->
          build_columns(range, granularity, day_px, today, assigns.translations)
      end
      |> pad_axis_columns()

    # --- Sub-project rollup (must run before partition) ---
    # A sub-project parent often has `start: nil, end: nil` and relies
    # on children's dates being rolled up to position it. If we partition
    # FIRST, those nil-date parents would be silently dropped before
    # their dates are computed — losing the entire sub-project — so we
    # roll up against the raw event list before classifying by range.
    rolled_up_events =
      assigns.events
      |> build_event_tree()
      |> then(&rollup_subproject_dates(assigns.events, &1))

    # Partition events by whether they overlap the visible POSITIONING window
    # (`view`), NOT `date_range`. These MUST use the same predicate as
    # `bar_geometry/4`: an event admitted here but clipped there returns
    # `%{out_of_range: true}` and the template's `bar.milestone` access crashes
    # (the bug a sub-day `window_start`/`window_end` reintroduced). Out-of-window
    # events are filtered from rendering (no row, no bar) but counted for the
    # edge indicators ("← N earlier / N later →").
    {in_range_events, earlier_count, later_count} =
      partition_events_by_range(rolled_up_events, view)

    # --- Visibility + retargeting ---
    # Re-build the parent/child tree on the in-range subset (children of
    # out-of-range parents become top-level), then filter to only visible
    # events (children of collapsed parents are hidden), and retarget
    # connector endpoints up the tree so arrows pointing to/from hidden
    # children attach to the visible roll-up ancestor instead.
    expanded_set = normalize_expanded(assigns.expanded, in_range_events)
    event_tree = build_event_tree(in_range_events)
    visible = visible_events(in_range_events, event_tree, expanded_set)
    retargeted_connectors = retarget_connectors(assigns.connectors, event_tree, expanded_set)

    # Sort events: topologically within each group, keeping direct dependents
    # adjacent to their sources to minimize arrow crossings. Events can override
    # the computed placement via `extra.order`.
    sorted_events =
      visible
      |> sort_events_for_layout(retargeted_connectors)
      |> cluster_subprojects(event_tree)

    in_range_ids = MapSet.new(sorted_events, & &1.id)

    # Build group boundaries for visual separators
    groups = build_groups(sorted_events)

    # Pre-compute Y position (top pixel) for each row — accounts for group headers
    row_positions = compute_row_positions(sorted_events, groups, row_px)
    total_content_height = row_positions.total_height

    # Bracketing frames for currently-expanded sub-projects (drawn in
    # the timeline column as a translucent rect with thick L/R borders).
    subproject_frames =
      compute_subproject_frames(
        sorted_events,
        event_tree,
        expanded_set,
        row_positions,
        row_px,
        view,
        day_px,
        min_bar_px
      )

    # Index events by id for connector lookups
    events_by_id = Map.new(sorted_events, &{&1.id, &1})

    # Non-working dates from day_markers
    non_working_dates = non_working_dates(assigns.day_markers)

    # Normalize connectors once (apply defaults for :type, :critical, :label).
    # Skip connectors touching any filtered (out-of-range) event — we'd have
    # nothing to anchor them to. In Phase 2 these become edge-markers on the
    # scroll viewport.
    normalized_connectors =
      retargeted_connectors
      |> Enum.filter(fn c ->
        MapSet.member?(in_range_ids, c.from) and MapSet.member?(in_range_ids, c.to)
      end)
      |> Enum.map(&normalize_connector/1)

    # Count outgoing/incoming per {event_id, type} so we can route shared
    # stems (bus routing — arrows from same source share exit stem; arrows
    # to same target share entry stem). Keyed by type to avoid collapsing
    # buses across dependency kinds that leave different bar edges.
    {outgoing_count, incoming_count} = count_connector_endpoints(normalized_connectors)

    # Per-{event_id, side} tally — counts arrows by attach class.
    # Four classes per side: out_up, out_down, in_above, in_below
    # (where "above/below" describes the OTHER end's row position).
    # Used by smart-mode attachment to decide which of the 4 designated y
    # positions an arrow lands at, and to collapse to bar center when only
    # one class is present on a side.
    side_tally = count_per_side(normalized_connectors, row_positions)

    # Lane assignment for stacked backward :fs arrows (multiple invalid
    # deps from the same source + direction) so they don't draw on top
    # of each other.
    backward_lanes =
      assign_backward_lanes(
        normalized_connectors,
        events_by_id,
        row_positions,
        view,
        day_px,
        min_bar_px
      )

    # Lane assignment for FORWARD bus stagger. Per-{event_id, side, direction}
    # bus, sorts members by other-end row position and assigns lane indices
    # 0..N-1. Used by `stagger_x_offset/3` to spread merged-bus arrows into
    # their own trunk x's when `bus_stagger_outgoing_px` /
    # `bus_stagger_incoming_px` (or per-task overrides) are non-zero.
    bus_lanes = assign_bus_lanes(normalized_connectors, row_positions)

    # Bar obstacle map for collision-aware trunk routing — skipped when
    # `avoid_collisions` is disabled so large Gantts pay zero cost.
    bar_obstacles =
      if assigns.avoid_collisions,
        do: compute_bar_obstacles(sorted_events, row_positions, view, day_px, row_px, min_bar_px),
        else: []

    # Bundle styling defaults so resolve_style/3 can pick the category
    # (normal / critical / invalid) and then let per-connector overrides
    # take priority.
    style_defaults = %{
      normal: %{
        color_class: assigns.connector_color_class,
        stroke_width: assigns.connector_stroke_width,
        opacity: assigns.connector_opacity,
        dasharray: assigns.connector_dasharray
      },
      critical: %{
        color_class: assigns.critical_color_class,
        stroke_width: assigns.critical_stroke_width,
        opacity: assigns.connector_opacity,
        dasharray: assigns.connector_dasharray
      },
      invalid: %{
        color_class: assigns.invalid_color_class,
        stroke_width: assigns.invalid_stroke_width,
        opacity: assigns.connector_opacity,
        dasharray: assigns.invalid_dasharray
      }
    }

    # Bundle the ambient routing context so the per-connector builders
    # don't have to thread 8+ positional args each.
    connector_ctx = %{
      events_by_id: events_by_id,
      row_positions: row_positions,
      range: range,
      view: view,
      day_px: day_px,
      min_bar_px: min_bar_px,
      row_px: row_px,
      content_width: content_width,
      outgoing_count: outgoing_count,
      incoming_count: incoming_count,
      side_tally: side_tally,
      backward_lanes: backward_lanes,
      bus_lanes: bus_lanes,
      bars: bar_obstacles,
      avoid_collisions: assigns.avoid_collisions,
      style_defaults: style_defaults,
      elbow_px: assigns.connector_elbow_px,
      bar_clearance_px: assigns.connector_bar_clearance_px,
      bus_split_offset_pct: assigns.bus_split_offset_pct,
      bus_attach_mode: assigns.bus_attach_mode,
      bus_attach_inner_pct: assigns.bus_attach_inner_pct,
      bus_stagger_outgoing_px: assigns.bus_stagger_outgoing_px,
      bus_stagger_incoming_px: assigns.bus_stagger_incoming_px,
      bus_stagger_corner_clearance_px: assigns.bus_stagger_corner_clearance_px
    }

    # Compute connector paths (list of %{d, from_id, to_id, type, critical,
    # invalid, label, label_x, label_y})
    connector_paths =
      if assigns.show_connectors,
        do: compute_connector_paths(normalized_connectors, connector_ctx),
        else: []

    assigns =
      assigns
      |> assign(:today, today)
      |> assign(:total_days, total_days)
      |> assign(:view, view)
      |> assign(:day_px, day_px)
      |> assign(:min_bar_px, min_bar_px)
      |> assign(:content_width, content_width)
      |> assign(:content_height, total_content_height)
      |> assign(:row_px, row_px)
      |> assign(:columns, columns)
      |> assign(:sorted_events, sorted_events)
      |> assign(:groups, groups)
      |> assign(:row_positions, row_positions)
      |> assign(:non_working_dates, non_working_dates)
      |> assign(:connector_paths, connector_paths)
      |> assign(:event_tree, event_tree)
      |> assign(:expanded_set, expanded_set)
      |> assign(:subproject_frames, subproject_frames)
      |> assign(:earlier_count, earlier_count)
      |> assign(:later_count, later_count)
      |> assign(:today_offscreen, today_offscreen_side(today, view))

    ~H"""
    <div class="lg-wrap relative" dir={to_string(@dir)}>
      <%!-- Self-contained fade rule used by the LgBarPopover hook
         when a popover opens — every bar/label/connector outside the
         active task's dependency tree gets `lg-faded` applied.
         Combines opacity + grayscale so colored bars actually read as
         "greyed out" (opacity alone leaves brand colors visible).
         Inline so the feature works even when consumers don't import
         the package CSS. --%>
      <style>
        .lg-faded {
          opacity: 0.3 !important;
          filter: grayscale(70%) !important;
          transition: opacity 150ms ease, filter 150ms ease;
        }

        /* Defensive guarantee: anything explicitly pinned by the
           LgBarPopover hook (the active task's bar, label,
           badges, popover) must NEVER appear faded — the JS adds
           `lg-pinned` to every element whose data-event-id
           matches the active task, regardless of what any other
           selector does. */
        .lg-pinned {
          opacity: 1 !important;
          filter: none !important;
        }

        /* Smooth slide for bottom-corner badges that the popover hook
           pushes down when its popover opens (and back up when it
           closes). Only `transform` is animated — `top` stays at its
           original computed value. */
        .lg-bar-badge[data-badge-corner^="bottom_"] {
          transition: transform 150ms ease;
        }
      </style>

      <%!-- "Too small to see" markers, decided in PURE CSS via a container
         query — no JavaScript measurement. Each marker sits inside a per-task
         container whose width tracks the bar's RENDERED width (same `%`, so it
         stretches with the responsive fill). The browser reveals the marker
         whenever that rendered width is at/under `tiny_bar_px`, and
         re-evaluates on resize automatically — so the decision is server-emitted
         + browser-resolved against true screen pixels, instant on first paint,
         no socket/hook needed. The threshold is `tiny_bar_px` (an integer attr,
         so safe to interpolate); injected raw because HEEx treats `<style>`
         bodies as opaque text (CSS braces aren't interpolation). Assumes a
         uniform `tiny_bar_px` across charts sharing a page. --%>
      <%= if @tiny_bar_px > 0 do %>
        {Phoenix.HTML.raw(
          "<style>.lg-tiny-marker{display:none}@container (max-width:#{@tiny_bar_px}px){.lg-tiny-marker{display:block}}</style>"
        )}
      <% end %>

      <%!-- Optional built-in toolbar (zoom switcher, today, prev/next).
           Sits above the scroll container so it doesn't scroll horizontally.
           Callbacks are wired by the consumer; the today button defaults to
           a JS.dispatch that the LgAutoScroll hook handles. That hook is only
           attached when `enable_hooks` is set, so the default scroll-to-today
           needs BOTH `id` and `enable_hooks` — otherwise the dispatch has no
           listener. A custom `on_scroll_today` works without hooks. The button
           is disabled (not silently dead) when neither path can fire. --%>
      <div :if={@show_header} class={@toolbar_class}>
        <div class="flex items-center gap-2">
          <button
            :if={@show_today_button}
            type="button"
            class="btn btn-xs btn-ghost lg-today-btn"
            phx-click={today_click_handler(@id, @on_scroll_today)}
            disabled={not today_button_functional?(@on_scroll_today, @id, @enable_hooks)}
            title={
              if not today_button_functional?(@on_scroll_today, @id, @enable_hooks),
                do: "Set enable_hooks + id (or on_scroll_today) to enable scroll-to-today"
            }
          >
            {I18n.label(:today, @translations)}
          </button>
          <div :if={@show_navigation and not is_nil(@on_navigate)} class="join">
            <button
              type="button"
              class="btn btn-xs btn-ghost join-item lg-nav-prev"
              phx-click={@on_navigate}
              phx-value-direction="prev"
              aria-label={I18n.label(:prev, @translations)}
            >
              ‹
            </button>
            <button
              type="button"
              class="btn btn-xs btn-ghost join-item lg-nav-next"
              phx-click={@on_navigate}
              phx-value-direction="next"
              aria-label={I18n.label(:next, @translations)}
            >
              ›
            </button>
          </div>
          {render_slot(@toolbar_start)}
        </div>
        <div class="flex items-center gap-2">
          <div
            :if={@show_zoom_switcher and not is_nil(@on_zoom_change)}
            class="join lg-zoom"
            role="group"
          >
            <button
              :for={z <- @zooms}
              type="button"
              class={[
                "btn btn-xs join-item",
                if(@zoom == z, do: "btn-primary", else: "btn-ghost")
              ]}
              phx-click={@on_zoom_change}
              phx-value-zoom={to_string(z)}
              aria-pressed={to_string(@zoom == z)}
            >
              {zoom_label(z, @translations)}
            </button>
          </div>
          {render_slot(@toolbar_end)}
        </div>
      </div>

      <%!-- Edge indicators — absolute-positioned pills that pin to the
           left/right of the wrap, staying in the viewport as the user
           scrolls the timeline horizontally. Clickable when the consumer
           wires `on_show_earlier` / `on_show_later`; otherwise rendered as
           informational badges (disabled button, no pointer events). --%>
      <button
        :if={@show_edge_indicators and @earlier_count > 0}
        type="button"
        class={["absolute left-2 z-40 lg-edge-earlier", @edge_indicator_class]}
        style={"top: #{edge_indicator_top_px(@show_header)}px"}
        phx-click={@on_show_earlier}
        disabled={is_nil(@on_show_earlier)}
        title={I18n.label(:earlier_tasks, @translations, %{count: @earlier_count})}
      >
        ← {I18n.label(:earlier_tasks, @translations, %{count: @earlier_count})}
      </button>
      <button
        :if={@show_edge_indicators and @later_count > 0}
        type="button"
        class={["absolute right-2 z-40 lg-edge-later", @edge_indicator_class]}
        style={"top: #{edge_indicator_top_px(@show_header)}px"}
        phx-click={@on_show_later}
        disabled={is_nil(@on_show_later)}
        title={I18n.label(:later_tasks, @translations, %{count: @later_count})}
      >
        {I18n.label(:later_tasks, @translations, %{count: @later_count})} →
      </button>

      <%!-- Off-screen today hint. When `today` falls outside `date_range`, we
           DON'T widen the axis to reach it — instead a directional pill pins to
           the edge pointing toward today. Sits below the edge-task indicators so
           the two never overlap. Clickable when `on_show_today` is wired
           (e.g. to widen the range / jump to today); otherwise informational. --%>
      <button
        :if={@show_today and @show_today_edge and @today_offscreen == :before}
        type="button"
        class={["absolute left-2 z-40 lg-today-edge", @edge_indicator_class]}
        style={"top: #{edge_indicator_top_px(@show_header) + 32}px"}
        phx-click={@on_show_today}
        disabled={is_nil(@on_show_today)}
        title={I18n.label(:today, @translations)}
      >
        ← {I18n.label(:today, @translations)}
      </button>
      <button
        :if={@show_today and @show_today_edge and @today_offscreen == :after}
        type="button"
        class={["absolute right-2 z-40 lg-today-edge", @edge_indicator_class]}
        style={"top: #{edge_indicator_top_px(@show_header) + 32}px"}
        phx-click={@on_show_today}
        disabled={is_nil(@on_show_today)}
        title={I18n.label(:today, @translations)}
      >
        {I18n.label(:today, @translations)} →
      </button>

      <div
        id={@id}
        class={["lg-chart overflow-x-auto bg-base-100", @class]}
        phx-hook={if @enable_hooks, do: "LgAutoScroll"}
        data-auto-scroll-today={to_string(@auto_scroll_today)}
      >
        <%!-- `min-w-full` makes the chart at least the viewport width (so a
             short timeline fills it) while still growing past it (and
             scrolling) when the natural content is wider. The timeline parts
             below `flex-1` + `min-width: content_width` to realize the
             fill-vs-scroll, all in CSS — no measurement, no round-trip. --%>
        <div class="flex flex-col relative min-w-full">
          <%!-- Column headers --%>
          <div class={["lg-header", @main_header_class]}>
            <%!-- Label column header --%>
            <div
              class={["lg-label-header", @label_header_class]}
              style={"width: #{Safe.sanitize_css_dimension(@label_width, "14rem")}"}
            >
              {I18n.label(:task, @translations)}
            </div>

            <%!-- Time columns. The bottom border + bg sit HERE (not on the
                 sticky header) so they span the full content width and stay put
                 under columns scrolled into view. --%>
            <div
              class="flex flex-1 bg-base-100 border-b-2 border-base-content/15"
              style={"min-width: #{@content_width}px"}
            >
              <div
                :for={col <- @columns}
                class={
                  unless col[:spacer] do
                    [
                      "lg-col-header",
                      @column_header_class,
                      col.is_today && @column_header_today_class
                    ]
                  end
                }
                style={"width: #{pct(col.width_px, @content_width)}%"}
              >
                {col.label}
              </div>
            </div>
          </div>

          <%!-- Body --%>
          <div class="flex relative">
            <%!-- Label column (left) --%>
            <div
              class={@label_col_class}
              style={"width: #{Safe.sanitize_css_dimension(@label_width, "14rem")}"}
            >
              <%= for {event, idx} <- Enum.with_index(@sorted_events) do %>
                <%!-- Group header row (inside label column) --%>
                <div
                  :if={show_group_header?(@groups, event, idx)}
                  class={["lg-group", @group_header_class]}
                  style={"height: #{@row_positions.group_header_px}px"}
                  data-group={get_group(event)}
                >
                  <span class={@group_header_text_class}>
                    {get_group(event) || I18n.label(:ungrouped, @translations)}
                  </span>
                </div>

                <% label_id = label_dom_id(@id, event.id) %>
                <% label_pop_id = label_popover_dom_id(@id, event.id) %>

                <% in_open_subproject? =
                  in_open_subproject?(event, @event_tree, @expanded_set) %>
                <% event_depth = depth_of(event.id, @event_tree) %>
                <%!-- 2 px offset so the rightmost guide line (drawn as a
                   `border-l-2`) stays uncovered to the LEFT of the bg.
                   `+ 12` so the bg also clears the chevron's own column
                   on the right side of the lines, leaving the chevron
                   visible against the row's normal background. --%>
                <% bg_start_px = max(0, event_depth - 1) * 12 + 14 %>
                <% row_color = frame_color_for(@subproject_frame_color, event_depth - 1) %>

                <%!-- Item label — clickable, opens the label popover --%>
                <div
                  id={label_id}
                  class={["lg-label", @label_row_class]}
                  style={
                    [
                      "height: #{@row_px}px",
                      in_open_subproject? &&
                        "background: linear-gradient(to right, transparent 0, transparent #{bg_start_px}px, #{row_color} #{bg_start_px}px)"
                    ]
                    |> Enum.filter(& &1)
                    |> Enum.join("; ")
                  }
                  data-event-id={event.id}
                  data-group={get_group(event)}
                  data-parent-id={parent_id_of(event)}
                  phx-hook={@enable_hooks && "LgBarPopover"}
                  data-popover-target={label_pop_id}
                >
                  <.subproject_chevron
                    event={event}
                    tree={@event_tree}
                    expanded={@expanded_set}
                    on_toggle={@on_toggle_expand}
                  />
                  <%= if @label != [] do %>
                    {render_slot(@label, event)}
                  <% else %>
                    <.default_label event={event} />
                  <% end %>
                </div>

                <%!-- Label popover — same shape as the bar popover but
                   anchored to the label row's y. Sibling of the row,
                   positioned absolutely against the label column (which
                   is `relative`).

                   `phx-update="ignore"` matches the bar popover so the
                   JS-applied `hidden` class survives LiveView diffs. --%>
                <div
                  id={label_pop_id}
                  class={["lg-label-popover", @label_popover_class]}
                  style={label_popover_style(@row_positions, event.id, @row_px)}
                  data-popover-for={label_id}
                  phx-update="ignore"
                  role="dialog"
                  aria-label={"Details for #{event.title}"}
                >
                  <div class={[
                    event.color || @bar_default_color_class,
                    event.text_color || Safe.infer_text_color(event.color),
                    event.status == :tentative && @status_tentative_class,
                    event.status == :cancelled && @status_cancelled_class,
                    event.status == :pending_approval && @status_pending_approval_class,
                    event.status == :no_show && @status_no_show_class,
                    event.status == :blocked && @status_blocked_class,
                    event.class
                  ]}>
                    <div
                      class={[
                        "lg-label-popover-title",
                        event.status == :cancelled && @bar_title_cancelled_class,
                        @bar_popover_title_class
                      ]}
                      style={"min-height: #{@row_px - 8}px"}
                    >
                      {event.title || "(No title)"}
                    </div>
                    <% label_subtitle = bar_subtitle(event) %>
                    <div
                      :if={label_subtitle}
                      class={[
                        "lg-label-popover-subtitle",
                        @bar_popover_subtitle_class
                      ]}
                    >
                      {label_subtitle}
                    </div>
                    <% label_actions =
                      popover_actions(event, @event_tree, @expanded_set, @on_toggle_expand) %>
                    <div
                      :if={label_actions != []}
                      class={[
                        "lg-label-popover-actions",
                        @bar_popover_actions_class
                      ]}
                    >
                      <.bar_action_button
                        :for={action <- label_actions}
                        action={action}
                        event_id={event.id}
                        class={@bar_action_button_class}
                        disabled_class={@bar_action_disabled_class}
                      />
                    </div>
                  </div>
                </div>
              <% end %>
            </div>

            <%!-- Bar/timeline column (right). Horizontal coords render as %
                 of this column's width; the px geometry is converted via
                 `pct/2`. `flex-1` + `min-width: content_width` lets it fill the
                 viewport (short chart) or grow + scroll (long chart). --%>
            <div
              class="relative flex-1"
              style={"min-width: #{@content_width}px; height: #{@content_height}px"}
            >
              <%!-- Grid background: column dividers + non-working day shading --%>
              <div class="absolute inset-0 flex pointer-events-none">
                <div
                  :for={col <- @columns}
                  class={
                    unless col[:spacer] do
                      [
                        @column_divider_class,
                        col.non_working && @non_working_class
                      ]
                    end
                  }
                  style={"width: #{pct(col.width_px, @content_width)}%"}
                >
                </div>
              </div>

              <%!-- Today marker line --%>
              <div
                :if={@show_today && today_in_range?(@today, @view)}
                class={["lg-today", @today_marker_line_class]}
                style={"left: #{pct(today_left_px(@today, @view, @day_px), @content_width)}%; height: #{@content_height}px"}
              >
                <div class={@today_marker_badge_class}>
                  {I18n.label(:today, @translations)}
                </div>
              </div>

              <%!-- Sub-project frames: a translucent rectangle that
                 spans each EXPANDED sub-project's roll-up bar PLUS
                 every descendant row, across the sub-project's date
                 range. Renders behind the bars (z-0); bars sit on
                 top at z-10. Color is inline rgba so it's guaranteed
                 to render regardless of Tailwind scanning. --%>
              <div
                :for={frame <- @subproject_frames}
                class="lg-subproject-frame absolute pointer-events-none rounded"
                style={"left: #{pct(frame.left_px, @content_width)}%; top: #{frame.top_y}px; width: #{pct(frame.right_px - frame.left_px, @content_width)}%; height: #{frame.bottom_y - frame.top_y}px; background-color: #{frame_color_for(@subproject_frame_color, frame.parent_depth)}; z-index: #{1 + frame.parent_depth}"}
              >
              </div>

              <%!-- Rows (bars) --%>
              <%= for {event, idx} <- Enum.with_index(@sorted_events) do %>
                <%!-- Empty spacer for group header (pushes bar down) --%>
                <div
                  :if={show_group_header?(@groups, event, idx)}
                  class={["lg-group-spacer", @group_spacer_class]}
                  style={"height: #{@row_positions.group_header_px}px"}
                  data-group={get_group(event)}
                >
                </div>

                <%!-- Bar row --%>
                <div class={@row_class} style={"height: #{@row_px}px"}>
                  <% bar = bar_geometry(event, @view, @day_px, @min_bar_px) %>
                  <% actions =
                    popover_actions(event, @event_tree, @expanded_set, @on_toggle_expand) %>
                  <% bar_id = bar_dom_id(@id, event.id) %>
                  <% popover_id = popover_dom_id(@id, event.id) %>

                  <%= if bar.milestone do %>
                    <div
                      id={bar_id}
                      class={[
                        "lg-milestone",
                        @milestone_class,
                        event.color || @milestone_default_color_class,
                        event.status == :cancelled && @milestone_status_cancelled_class,
                        event.class
                      ]}
                      style={"left: #{pct(bar.left_px, @content_width)}%; transform: translate(-50%, -50%) rotate(45deg)"}
                      phx-click={@on_event_click}
                      phx-value-event-id={event.id}
                      phx-hook={@enable_hooks && "LgBarPopover"}
                      data-popover-target={popover_id}
                      data-event-id={event.id}
                      data-group={get_group(event)}
                      data-parent-id={parent_id_of(event)}
                      title={event.title}
                    >
                    </div>
                  <% else %>
                    <div
                      id={bar_id}
                      class={[
                        "lg-bar",
                        @bar_class,
                        sub_project?(event, @event_tree) && @bar_subproject_class,
                        event.class
                      ]}
                      style={"left: #{pct(bar.left_px, @content_width)}%; width: #{pct(bar.width_px, @content_width)}%"}
                      phx-click={@on_event_click}
                      phx-value-event-id={event.id}
                      phx-hook={@enable_hooks && "LgBarPopover"}
                      data-popover-target={popover_id}
                      data-event-id={event.id}
                      data-group={get_group(event)}
                      data-parent-id={parent_id_of(event)}
                      title={bar_title(event)}
                    >
                      <%!-- Background --%>
                      <div class={[
                        @bar_background_class,
                        event.color || @bar_default_color_class,
                        event.status == :tentative && @status_tentative_class,
                        event.status == :cancelled && @status_cancelled_class,
                        event.status == :pending_approval && @status_pending_approval_class,
                        event.status == :no_show && @status_no_show_class,
                        event.status == :blocked && @status_blocked_class
                      ]}>
                      </div>

                      <%!-- Progress fill --%>
                      <div
                        :if={@show_progress && progress_pct(event) > 0}
                        class={[
                          @progress_class,
                          progress_pct(event) >= 100 && @progress_complete_radius_class,
                          if(progress_pct(event) >= 100,
                            do: @progress_complete_class,
                            else: @progress_incomplete_class
                          )
                        ]}
                        style={"width: #{min(progress_pct(event), 100)}%"}
                      >
                      </div>

                      <%!-- Label on bar --%>
                      <%= if @item != [] do %>
                        <div class="relative z-10 w-full">
                          {render_slot(@item, event)}
                        </div>
                      <% else %>
                        <span class={[
                          @bar_title_class,
                          event.text_color || Safe.infer_text_color(event.color),
                          event.status == :cancelled && @bar_title_cancelled_class
                        ]}>
                          {event.title || "(No title)"}
                        </span>
                      <% end %>
                    </div>

                    <%!-- Too-small-to-see marker. A bar whose TRUE width is
                       sub-pixel at the current zoom/fill renders as a hairline
                       (or vanishes). This fixed-size down-triangle, anchored at
                       the task's start, signals "a task lives here".

                       The container's width tracks the bar's RENDERED width (same
                       `%`), and `container-type: inline-size` makes it a CSS
                       container-query target — the stylesheet above reveals the
                       inner marker purely when that rendered width is at/under
                       `tiny_bar_px` screen px. No JS measures anything: the server
                       emits the rule, the browser resolves it (and re-resolves on
                       resize). The marker keeps the bar's popover wiring so it's
                       clickable even when the bar is ~0px. --%>
                    <div
                      :if={@tiny_bar_px > 0}
                      class="lg-tiny-container absolute pointer-events-none"
                      style={"left: #{pct(bar.left_px, @content_width)}%; top: 0; width: #{pct(bar.width_px, @content_width)}%; height: 0; container-type: inline-size"}
                    >
                      <div
                        id={"#{bar_id}-tiny"}
                        class={[
                          "lg-tiny-marker absolute z-30 cursor-pointer pointer-events-auto",
                          event.color || @bar_default_color_class
                        ]}
                        style="left: 0; top: 2px; width: 10px; height: 7px; transform: translateX(-50%); clip-path: polygon(0 0, 100% 0, 50% 100%)"
                        phx-hook={@enable_hooks && "LgBarPopover"}
                        data-popover-target={popover_id}
                        data-event-id={event.id}
                        title={event.title}
                      >
                      </div>
                    </div>

                    <%!-- Bar badges — siblings of the bar (so the bar's
                       overflow-hidden doesn't clip them). Each one
                       positions itself in a corner of the bar's
                       rectangle. Per-corner stacking offset prevents
                       multiple badges in the same corner from sitting
                       on top of each other. --%>
                    <.bar_badge
                      :for={{badge, corner_index} <- bar_badges_with_offsets(event)}
                      badge={badge}
                      corner_index={corner_index}
                      bar={bar}
                      row_px={@row_px}
                      content_width={@content_width}
                      event_id={event.id}
                      class={@badge_class}
                      default_color={@badge_default_color_class}
                    />
                  <% end %>

                  <%!-- Popover anchored to the bar / milestone's left edge —
                       sibling (not child) so the bar's overflow-hidden doesn't
                       clip it, and rendered for BOTH bars and milestones so a
                       diamond is clickable too (otherwise a milestone shows a
                       cursor-pointer but has nowhere to click to). Always
                       rendered so any task can show its full title; the action
                       row only appears when actions exist. Hidden by default;
                       the LgBarPopover hook toggles `hidden` on click.

                       `phx-update="ignore"` keeps the JS-applied `hidden`
                       class (and any toggled state) from being wiped on
                       every LiveView diff. The popover's content reflects
                       the initial server render — re-rendering would
                       require remounting (e.g. swapping the bar id). --%>
                  <div
                    id={popover_id}
                    class={["lg-bar-popover", @bar_popover_class]}
                    style={popover_style(bar, @row_px, @content_width)}
                    data-popover-for={bar_id}
                    phx-update="ignore"
                    role="dialog"
                    aria-label={"Details for #{event.title}"}
                  >
                    <%!-- Colored wrapper: carries the bar's color +
                         text + status + custom class so BOTH the title
                         row AND the actions row share the look (and
                         pulse together for `:pending_approval`). One
                         visual block — the popover reads as the bar
                         expanding open. --%>
                    <div class={[
                      event.color || @bar_default_color_class,
                      event.text_color || Safe.infer_text_color(event.color),
                      event.status == :tentative && @status_tentative_class,
                      event.status == :cancelled && @status_cancelled_class,
                      event.status == :pending_approval && @status_pending_approval_class,
                      event.status == :no_show && @status_no_show_class,
                      event.status == :blocked && @status_blocked_class,
                      event.class
                    ]}>
                      <div
                        class={[
                          "lg-bar-popover-title",
                          event.status == :cancelled && @bar_title_cancelled_class,
                          @bar_popover_title_class
                        ]}
                        style={"min-height: #{@row_px - 8}px"}
                      >
                        {event.title || "(No title)"}
                      </div>
                      <% subtitle = bar_subtitle(event) %>
                      <div
                        :if={subtitle}
                        class={[
                          "lg-bar-popover-subtitle",
                          @bar_popover_subtitle_class
                        ]}
                      >
                        {subtitle}
                      </div>
                      <div
                        :if={actions != []}
                        class={[
                          "lg-bar-popover-actions",
                          @bar_popover_actions_class
                        ]}
                      >
                        <.bar_action_button
                          :for={action <- actions}
                          action={action}
                          event_id={event.id}
                          class={@bar_action_button_class}
                          disabled_class={@bar_action_disabled_class}
                        />
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>

              <%!-- SVG connector SHAFTS. The viewBox stays in PIXELS (the
                   routing math is unchanged) but the element renders at
                   `width: 100%` with `preserveAspectRatio="none"`, so the
                   px paths stretch horizontally in lockstep with the
                   %-positioned bars (both reduce to frac/total × renderedWidth)
                   and stay aligned at any width. `non-scaling-stroke` keeps line
                   thickness crisp. A stretched LINE is still a correct line, so
                   shafts can stretch — arrowHEADS can't (a stretched triangle is
                   not a triangle), so they render separately below. --%>
              <svg
                :if={@connector_paths != []}
                class="lg-connectors absolute top-0 left-0 pointer-events-none z-20 overflow-visible"
                width="100%"
                height={@content_height}
                viewBox={"0 0 #{@content_width} #{@content_height}"}
                preserveAspectRatio="none"
              >
                <path
                  :for={p <- @connector_paths}
                  d={p.d}
                  fill="none"
                  stroke-width={p.stroke_width}
                  stroke-dasharray={p.dasharray}
                  opacity={p.opacity}
                  vector-effect="non-scaling-stroke"
                  class={["lg-connector stroke-current", p.color_class]}
                  data-from-id={p.from_id}
                  data-to-id={p.to_id}
                  data-type={p.type}
                  data-critical={to_string(p.critical)}
                  data-invalid={to_string(p.invalid)}
                />
                <%!-- Optional solid rect behind label (opt-in via `label_background={:rect}`).
                   Better contrast over bars, at the cost of a visible gap
                   in the line around narrow labels where the rect extends
                   past the actual glyph width. --%>
                <rect
                  :for={p <- @connector_paths}
                  :if={p.label && @label_background == :rect}
                  x={p.label_x - div(p.label_width, 2) - 2}
                  y={p.label_y - 6}
                  width={p.label_width + 4}
                  height={12}
                  rx="2"
                  class="lg-connector-label-bg fill-base-100"
                  transform={p.label_transform}
                  data-from-id={p.from_id}
                  data-to-id={p.to_id}
                />
                <%!-- Label text. Always carries a base-100 halo (paint-order=stroke
                   draws the outline before the fill, giving each glyph a ~3px
                   background-colored margin). In :halo mode it's the only
                   background treatment; in :rect mode it fills any gap where
                   the text extends past the rect. --%>
                <text
                  :for={p <- @connector_paths}
                  :if={p.label}
                  x={p.label_x}
                  y={p.label_y}
                  text-anchor="middle"
                  dominant-baseline="middle"
                  stroke-width="3"
                  paint-order="stroke"
                  class={[
                    "lg-connector-label text-[0.6rem] font-medium select-none",
                    "fill-current stroke-base-100",
                    p.color_class
                  ]}
                  transform={p.label_transform}
                  data-from-id={p.from_id}
                  data-to-id={p.to_id}
                >
                  {p.label}
                </text>
              </svg>
              <%!-- Arrowhead overlay — a px-faithful layer OUTSIDE the stretched
                   shaft SVG. Each head is anchored by % (so its tip tracks the
                   bar-aligned path end as the chart fills/scrolls) but drawn at a
                   FIXED px size (so it stays a crisp triangle at any fill factor).
                   `color_class` is mirrored from the shaft so head + line recolor
                   together. The inner svg is nudged so its triangle TIP lands
                   exactly on the anchor point. --%>
              <div
                :if={@connector_paths != []}
                class="lg-arrowheads absolute top-0 left-0 w-full pointer-events-none z-20"
                style={"height: #{@content_height}px"}
              >
                <div
                  :for={p <- @connector_paths}
                  class={["lg-arrowhead absolute", p.arrow.variant_class, p.color_class]}
                  style={"left: #{pct(p.arrow.tip_x, @content_width)}%; top: #{p.arrow.tip_y}px"}
                  data-from-id={p.from_id}
                  data-to-id={p.to_id}
                >
                  <svg
                    class="absolute block overflow-visible"
                    width={p.arrow.size}
                    height={p.arrow.size}
                    viewBox={"0 0 #{p.arrow.size} #{p.arrow.size}"}
                    style={"left: #{p.arrow.off_x}px; top: #{p.arrow.off_y}px"}
                  >
                    <path d={p.arrow.d} class="fill-current" />
                  </svg>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Sub-project chevron component --
  #
  # Indents the label by `depth * 12px` (one level per nested
  # sub-project) and prepends a clickable chevron when the event is
  # itself a sub-project. Non-sub-project rows get a same-width
  # spacer so labels stay vertically aligned across depths. Clicking
  # the chevron pushes the consumer's `on_toggle_expand` event with
  # `event-id` so they can flip that id in their `expanded` set.

  attr :event, LiveGantt.Task, required: true
  attr :tree, :map, required: true
  attr :expanded, :any, required: true
  attr :on_toggle, :any, required: true

  defp subproject_chevron(assigns) do
    depth = depth_of(assigns.event.id, assigns.tree)

    assigns =
      assigns
      |> assign(:depth, depth)
      |> assign(:is_sub, sub_project?(assigns.event, assigns.tree))
      |> assign(:expanded?, MapSet.member?(assigns.expanded, assigns.event.id))
      |> assign(:depth_columns, if(depth > 0, do: Enum.to_list(1..depth), else: []))

    ~H"""
    <div class="flex-shrink-0 flex items-stretch self-stretch mr-1">
      <%!-- One vertical guide line per nesting depth — visually
         links the child back up to its sub-project parent. --%>
      <div
        :for={_ <- @depth_columns}
        class="flex-shrink-0 w-3 border-l-2 border-base-content/20"
      >
      </div>
      <%!-- Chevron slot (or spacer for leaf rows so labels align).
         Use heroicon SVG (`hero-plus-mini` / `hero-minus-mini`) for
         the +/− glyph — the icons are designed to centre on their
         viewBox, so they always sit dead-centre of the 20 px button
         regardless of font metrics. --%>
      <div class="flex-shrink-0 w-5 flex items-center justify-center">
        <button
          :if={@is_sub}
          type="button"
          class="lg-subproject-chevron inline-flex items-center justify-center w-5 h-5 rounded bg-base-content/10 hover:bg-base-content/25 text-base-content cursor-pointer"
          title={if @expanded?, do: "Collapse sub-project", else: "Expand sub-project"}
          phx-click={@on_toggle}
          phx-value-event-id={@event.id}
        >
          <span class={if @expanded?, do: "hero-minus-mini w-4 h-4", else: "hero-plus-mini w-4 h-4"}>
          </span>
        </button>
      </div>
    </div>
    """
  end

  # -- Default label component --

  attr :event, LiveGantt.Task, required: true

  defp default_label(assigns) do
    ~H"""
    <div class="flex items-center gap-2 min-w-0 w-full">
      <div
        :if={@event.color}
        class={["w-2 h-2 rounded-full flex-shrink-0", @event.color]}
      >
      </div>
      <span :if={@event.icon} class="flex-shrink-0 text-xs">{@event.icon}</span>
      <span class={[
        "text-sm truncate flex-1",
        @event.status == :cancelled && "line-through text-base-content/50"
      ]}>
        {@event.title || "(No title)"}
      </span>
      <span
        :if={assignee(@event)}
        class="text-[0.6rem] text-base-content/40 truncate flex-shrink-0"
      >
        {assignee(@event)}
      </span>
    </div>
    """
  end

  # -- Column building (returns columns with pixel widths) --

  # Wrap the time columns with a transparent spacer on each side, so the grid
  # occupies `[@axis_pad_px, content_width - @axis_pad_px]` — matching the
  # coordinate shift in `x_px`/`bar_geometry`. The spacer carries no label,
  # border, or shading: it's pure margin where an edge-of-window connector stub
  # can draw instead of clipping off the chart.
  defp pad_axis_columns(columns) do
    spacer = %{
      label: "",
      width_px: @axis_pad_px,
      is_today: false,
      non_working: false,
      spacer: true
    }

    [spacer | columns] ++ [spacer]
  end

  # Per-hour columns (24 per day). The day's date is shown on the 00:00 column,
  # the hour number on the rest. The column matching `now` (when `today` carries
  # a time) is flagged `is_today` so the current hour highlights.
  defp build_columns(range, :hour, day_px, today, tr) do
    hour_px = round(day_px / 24)
    now = if match?(%DateTime{}, today) or match?(%NaiveDateTime{}, today), do: today, else: nil

    for date <- range, hour <- 0..23 do
      %{
        label:
          if(hour == 0,
            do: "#{I18n.month_name_short(date.month, tr)} #{date.day}",
            else: "#{hour}"
          ),
        width_px: hour_px,
        is_today: hour_is_now?(date, hour, now),
        non_working: Date.day_of_week(date) in [6, 7]
      }
    end
  end

  # Sub-hour columns: 15-minute (96/day) and 5-minute (288/day) slots labelled
  # with clock times (7:00, 7:15, …) instead of the meaningless hour ordinal.
  # The day's date sits on the 00:00 slot. `:min5` labels only every third slot
  # (the 15-minute boundaries) so the 5-minute gridlines don't crowd into an
  # unreadable wall of text.
  defp build_columns(range, :min15, day_px, today, tr),
    do: sub_hour_columns(range, day_px, today, 15, 1, tr)

  defp build_columns(range, :min5, day_px, today, tr),
    do: sub_hour_columns(range, day_px, today, 5, 3, tr)

  defp build_columns(range, :day, day_px, today, _tr) do
    today_date = to_date(today)

    Enum.map(range, fn date ->
      %{
        label: "#{date.day}",
        width_px: day_px,
        is_today: date == today_date,
        non_working: Date.day_of_week(date) in [6, 7]
      }
    end)
  end

  defp build_columns(range, :week, day_px, today, tr) do
    today_date = to_date(today)
    dates = Enum.to_list(range)

    dates
    |> Enum.chunk_by(fn d -> {d.year, elem(:calendar.iso_week_number(Date.to_erl(d)), 1)} end)
    |> Enum.map(fn chunk ->
      first = hd(chunk)
      days_in_chunk = length(chunk)

      %{
        label: week_label(first, days_in_chunk, tr),
        width_px: days_in_chunk * day_px,
        is_today: today_date in chunk,
        non_working: false
      }
    end)
  end

  defp build_columns(range, :month, day_px, today, tr) do
    today_date = to_date(today)
    dates = Enum.to_list(range)

    dates
    |> Enum.chunk_by(fn d -> {d.year, d.month} end)
    |> Enum.map(fn chunk ->
      first = hd(chunk)
      days_in_chunk = length(chunk)

      %{
        label: month_label(first, tr),
        width_px: days_in_chunk * day_px,
        is_today: today_date in chunk,
        non_working: false
      }
    end)
  end

  defp build_columns(range, _zoom, day_px, today, tr),
    do: build_columns(range, :week, day_px, today, tr)

  defp sub_hour_columns(range, day_px, today, minutes_per_slot, label_every, tr) do
    slots_per_day = div(1440, minutes_per_slot)
    col_px = round(day_px / slots_per_day)
    now = if match?(%DateTime{}, today) or match?(%NaiveDateTime{}, today), do: today, else: nil

    for date <- range, slot <- 0..(slots_per_day - 1) do
      minute_of_day = slot * minutes_per_slot
      h = div(minute_of_day, 60)
      m = rem(minute_of_day, 60)

      label =
        cond do
          slot == 0 -> "#{I18n.month_name_short(date.month, tr)} #{date.day}"
          rem(slot, label_every) == 0 -> "#{h}:#{pad2(m)}"
          true -> ""
        end

      %{
        label: label,
        width_px: col_px,
        is_today: slot_is_now?(date, minute_of_day, minutes_per_slot, now),
        non_working: Date.day_of_week(date) in [6, 7]
      }
    end
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Minutes per column slot for a sub-day granularity. Drives `window_columns`.
  defp slot_minutes(:hour), do: 60
  defp slot_minutes(:min15), do: 15
  defp slot_minutes(:min5), do: 5

  # Columns for a sub-day positioning window (origin is a NaiveDateTime partway
  # through a day, not a midnight Date). `build_columns`/`sub_hour_columns`
  # enumerate whole days from a `Date.Range`; here we instead walk fixed
  # `minutes_per_slot` steps from the origin across the window span. Labels match
  # the whole-day builders: the date on each midnight slot, a bare hour on
  # `:hour` zoom, and the `:15` clock boundaries on sub-hour zooms (the in-between
  # 5-minute gridlines stay blank). The consumer snaps `window_start` to a slot
  # boundary so these labels land on round times.
  defp window_columns(%NaiveDateTime{} = origin, span_days, day_px, minutes_per_slot, today, tr) do
    slots_per_day = div(1440, minutes_per_slot)
    col_px = round(day_px / slots_per_day)
    num_slots = max(round(span_days * slots_per_day), 1)
    now = if match?(%DateTime{}, today) or match?(%NaiveDateTime{}, today), do: today, else: nil

    for i <- 0..(num_slots - 1) do
      slot_dt = NaiveDateTime.add(origin, i * minutes_per_slot, :minute)
      date = NaiveDateTime.to_date(slot_dt)
      minute_of_day = slot_dt.hour * 60 + slot_dt.minute

      label =
        cond do
          minute_of_day == 0 ->
            "#{I18n.month_name_short(date.month, tr)} #{date.day}"

          minutes_per_slot == 60 ->
            "#{slot_dt.hour}"

          rem(minute_of_day, 15) == 0 ->
            "#{slot_dt.hour}:#{pad2(slot_dt.minute)}"

          true ->
            ""
        end

      %{
        label: label,
        width_px: col_px,
        is_today: slot_is_now?(date, minute_of_day, minutes_per_slot, now),
        non_working: Date.day_of_week(date) in [6, 7]
      }
    end
  end

  @doc """
  The default pixels-per-day for a zoom level — `:hour` 720, `:day` 40,
  `:week` 24, `:month` 8. Use it as the floor when computing a fit-to-width
  `day_width_px` override, so fitting only ever *widens* (and a long chart still
  scrolls at its natural density).
  """
  @spec default_day_width_px(atom()) :: pos_integer()
  def default_day_width_px(zoom), do: day_width_px(zoom)

  @doc """
  The fixed horizontal margin (px) reserved on EACH side of the time axis so a
  connector exiting/entering a task at the very edge of the window has room to
  draw instead of clipping. The natural content width is
  `total_days × day_width_px + 2 × axis_pad_px()`. A consumer computing a
  fit-to-width `day_width_px` from a measured viewport should subtract
  `2 × axis_pad_px()` first.
  """
  @spec axis_pad_px() :: non_neg_integer()
  def axis_pad_px, do: @axis_pad_px

  # `:hour` zoom makes a day 720px wide (24 × 30px/hour) so intra-day bars and
  # per-hour columns are legible. The wide content scrolls. `:min15` is sized so
  # a 15-min column is ~45px — enough for a `0:45`-style label to breathe rather
  # than four crammed clock times per hour.
  defp day_width_px(:min5), do: 8640
  defp day_width_px(:min15), do: 4320
  defp day_width_px(:hour), do: 720
  defp day_width_px(:day), do: 40
  defp day_width_px(:week), do: 24
  defp day_width_px(:month), do: 8
  defp day_width_px(_), do: 24

  # Choose the COLUMN granularity for a given continuous density (px/day),
  # independent of any named zoom. This is what makes continuous zoom work: the
  # density can sit anywhere between the named presets, and the header columns
  # snap to whatever granularity reads well at that density (the preset px values
  # double as the thresholds, so each granularity's columns stay legibly wide).
  # Capped so a wide range at a fine density doesn't emit tens of thousands of
  # column divs — it steps to a coarser granularity instead (the bars keep their
  # true density; only the gridlines coarsen). Generous enough that the named
  # sub-hour zooms keep their clock-time columns at typical project lengths —
  # 15-min up to ~31 days, 5-min up to ~10 days — before stepping coarser; a
  # few thousand lightweight column divs render fine.
  @column_budget 3000

  defp column_zoom_for(day_px, total_days) do
    by_density =
      cond do
        day_px >= 8640 -> :min5
        day_px >= 4320 -> :min15
        day_px >= 720 -> :hour
        day_px >= 40 -> :day
        day_px >= 16 -> :week
        true -> :month
      end

    cap_columns(by_density, total_days)
  end

  @column_order [:min5, :min15, :hour, :day, :week, :month]

  defp cap_columns(gran, total_days) do
    @column_order
    |> Enum.drop_while(&(&1 != gran))
    |> Enum.find(:month, fn g -> column_count(g, total_days) <= @column_budget end)
  end

  defp column_count(:min5, days), do: days * 288
  defp column_count(:min15, days), do: days * 96
  defp column_count(:hour, days), do: days * 24
  defp column_count(:day, days), do: days
  defp column_count(:week, days), do: ceil(days / 7)
  defp column_count(:month, days), do: ceil(days / 30)

  defp week_label(first_day, days_count, tr) do
    if days_count >= 5 do
      {_year, week} = :calendar.iso_week_number(Date.to_erl(first_day))
      "W#{week}"
    else
      "#{I18n.month_name_short(first_day.month, tr)} #{first_day.day}"
    end
  end

  defp month_label(date, tr) do
    "#{I18n.month_name_short(date.month, tr)} #{date.year}"
  end

  # -- Row position pre-computation --
  # Returns %{
  #   positions: %{event_id => %{top: px, center: px}},
  #   group_header_px: px,
  #   total_height: px
  # }

  defp compute_row_positions(sorted_events, groups, row_px) do
    {positions, total} =
      sorted_events
      |> Enum.with_index()
      |> Enum.reduce({%{}, 0}, fn {event, idx}, {acc, y} ->
        # Add group header height if this event starts a new group
        y = if show_group_header?(groups, event, idx), do: y + @group_header_px, else: y

        entry = %{top: y, center: y + div(row_px, 2)}
        {Map.put(acc, event.id, entry), y + row_px}
      end)

    %{
      positions: positions,
      group_header_px: @group_header_px,
      total_height: total
    }
  end

  # -- Bar geometry (pixel-based) --

  # --- Continuous time→pixel coordinate ---
  #
  # The whole chart positions everything (bars, today marker, connector
  # endpoints, columns) on ONE axis: "fractional days from `range.first`". This
  # is what lets `:hour` (and finer) zoom work without a second coordinate
  # engine — zoom only changes `day_px` and column generation.
  #
  # `frac_days/2` accepts `Date` (midnight), `NaiveDateTime`, or `DateTime`
  # (positioned by WALL-CLOCK time, not elapsed seconds, so a DST day isn't 23
  # or 25 px-hours wide). `x_px/3` rounds to a whole pixel — so for a `Date` at
  # day/week/month zoom it is byte-identical to the old `Date.diff * day_px`,
  # keeping existing behavior; sub-day precision is purely additive.
  # The origin may be a `Date` (the whole-day window — `range.first`) OR a
  # `NaiveDateTime` (a sub-day window, so the axis can start partway through a
  # day). Date-origin + Date-temporal keeps the exact integer-day path, so
  # day/week/month geometry is byte-identical; everything else normalises to
  # naive datetimes and diffs in seconds.
  defp frac_days(nil, _origin), do: 0.0
  defp frac_days(%Date{} = d, %Date{} = origin), do: Date.diff(d, origin) * 1.0

  defp frac_days(temporal, origin),
    do: NaiveDateTime.diff(to_naive_dt(temporal), to_naive_dt(origin), :second) / 86_400

  defp to_naive_dt(%NaiveDateTime{} = n), do: n
  defp to_naive_dt(%Date{} = d), do: NaiveDateTime.new!(d, ~T[00:00:00])
  defp to_naive_dt(%DateTime{} = dt), do: DateTime.to_naive(dt)

  # `@axis_pad_px` shifts the whole coordinate system right so x=0 (the window
  # origin) sits a margin in from the chart's left edge, leaving room for a
  # connector stub that exits/enters a task at the very edge. `content_width`
  # carries the matching 2× growth and spacer columns hold the margin, so bars
  # still exactly cover their time columns — only the absolute %s move.
  defp x_px(temporal, origin, day_px),
    do: @axis_pad_px + round(frac_days(temporal, origin) * day_px)

  # Horizontal coordinates render as PERCENTAGES of the content width, not
  # pixels — so the timeline is responsive: it fills the container when the
  # natural content (`total_days * day_px`, kept as the scroll `min-width`) is
  # narrower, and scrolls when wider, with zero JS. Every px coordinate (shifted
  # right by `@axis_pad_px`) and `content_width` (`total_days * day_px + 2 *
  # @axis_pad_px`) share the same scale, so a single divide converts to a percent
  # and bars, columns, and connectors all stay aligned regardless of the pad.
  defp pct(_px, content_width) when content_width in [0, nil], do: 0.0
  defp pct(px, content_width), do: Float.round(px / content_width * 100, 4)

  # `view` is `{origin, span_days}` — the positioning origin (a `Date` for a
  # whole-day window or a `NaiveDateTime` for a sub-day one) and the visible
  # span in (fractional) days. `{range.first, total_days}` reproduces the old
  # whole-day behaviour exactly.
  defp bar_geometry(event, {origin, span_days} = _view, day_px, min_bar_px) do
    fs = frac_days(event.start, origin)
    fe = frac_days(LiveGantt.Task.effective_end(event), origin)
    is_milestone = fe - fs <= 0

    cond do
      out_of_range_frac?(fs, fe, is_milestone, span_days) ->
        %{out_of_range: true}

      is_milestone ->
        %{
          left_px: @axis_pad_px + max(round(fs * day_px), 0),
          width_px: 0,
          milestone: true,
          out_of_range: false
        }

      true ->
        vis_start = max(fs, 0.0)
        vis_end = min(fe, span_days)
        left_px = @axis_pad_px + max(round(vis_start * day_px), 0)
        # Width reflects the TRUE duration; `min_bar_px` (default 0) is an
        # optional floor so a sub-pixel task can stay a visible sliver. With the
        # default the bar is honest — a too-short-to-see task is a hairline until
        # zoomed in — and connectors attach to this same (un-inflated) edge.
        width_px = max(round((vis_end - vis_start) * day_px), min_bar_px)
        %{left_px: left_px, width_px: width_px, milestone: false, out_of_range: false}
    end
  end

  # Overlap test in fractional-day space (relative to range.first, so range
  # spans [0, total_days)). A milestone is its single instant; a ranged event
  # is the half-open `[fs, fe)`.
  defp out_of_range_frac?(fs, _fe, true, total_days), do: fs < 0 or fs >= total_days
  defp out_of_range_frac?(fs, fe, false, total_days), do: fe <= 0 or fs >= total_days

  # -- Connector path (orthogonal routing) --
  #
  # Supports the four standard Gantt dependency types:
  #
  #   :fs — finish-to-start  (default) — A must finish before B can start
  #   :ss — start-to-start              — A must start   before B can start
  #   :ff — finish-to-finish            — A must finish  before B can finish
  #   :sf — start-to-finish             — A must start   before B can finish
  #
  # Every arrow is the same three-segment shape `M x1 y1 H mid V y2 H x2`.
  # The type only changes where x1, x2, and mid_x sit and which side of
  # each bar the stem exits / enters, which flips the arrowhead direction
  # via SVG's `orient="auto"`.
  #
  # A "backward" / invalid schedule (the later task is actually scheduled
  # earlier than the constraint allows) is detected uniformly by
  # `conflict?/3`. For :fs we draw a five-segment detour because the
  # forward stems point INTO each other and can't resolve; for :ss/:ff/:sf
  # the normal three-segment shape stays coherent because both stems exit
  # the same side of their respective bars.
  #
  # Connectors may also carry:
  #
  #   critical: true   — rendered with primary color, thicker stroke,
  #                      and the `lg-arrow-critical` marker
  #   label: "2d lag"  — rendered as <text> with a base-100 halo near
  #                      the path midpoint (forward) or detour leg
  #                      (backward) for lag/lead annotations

  # Normalize a consumer-supplied connector into a struct with defaults.
  #
  # Every field beyond from/to is optional. Styling overrides
  # (color_class/stroke_width/opacity/dasharray) default to nil and are
  # resolved against the component-level defaults in `resolve_style/3`.
  # Routing overrides (exit_stem/entry_stem/detour_side/bar_clearance/
  # avoid_collisions/shape) default to nil (or :auto for enums) and are
  # checked inline in the path builders.
  defp normalize_connector(conn) do
    %{
      from: conn.from,
      to: conn.to,
      type: Map.get(conn, :type, :fs),
      critical: Map.get(conn, :critical, false),
      label: Map.get(conn, :label),
      label_orientation: Map.get(conn, :label_orientation, :horizontal),
      color_class: Map.get(conn, :color_class),
      stroke_width: Map.get(conn, :stroke_width),
      opacity: Map.get(conn, :opacity),
      dasharray: Map.get(conn, :dasharray),
      exit_stem: Map.get(conn, :exit_stem),
      entry_stem: Map.get(conn, :entry_stem),
      detour_side: Map.get(conn, :detour_side, :auto),
      bar_clearance: Map.get(conn, :bar_clearance),
      avoid_collisions: Map.get(conn, :avoid_collisions),
      shape: Map.get(conn, :shape, :auto)
    }
  end

  defp compute_connector_paths(normalized_connectors, ctx) do
    normalized_connectors
    |> Enum.flat_map(fn conn ->
      case connector_path(conn, ctx) do
        nil -> []
        path -> [path]
      end
    end)
    |> consolidate_piercing_trunks(ctx)
    |> Enum.map(&finalize_arrowhead/1)
  end

  # Compute each connector's arrowhead AFTER all path rewrites
  # (`consolidate_piercing_trunks` can replace a forward path's `d` with a
  # multi-hop jog that ENDS AT A DIFFERENT POINT than the original). The head
  # must sit on the shaft's ACTUAL end — the old `marker-end` rode the path so
  # this was automatic; the separate overlay layer must re-derive it from the
  # final `d`. We read the last point + final-segment direction generically, so
  # it's correct for the 3-seg forward, 5-seg detour, and N-seg jog alike.
  defp finalize_arrowhead(p) do
    {tip_x, tip_y, dir} = arrowhead_from_d(p.d)

    variant =
      cond do
        p.invalid -> :invalid
        p.critical -> :critical
        true -> :normal
      end

    %{p | arrow: arrowhead_geometry(tip_x, tip_y, dir, variant, p.target_milestone)}
  end

  # Post-pass: for every FORWARD path whose trunk pierces an unrelated
  # bar, try to repair it without leaving the chart:
  #
  #   1. Single-column shift to a sibling's lane that's clean for the
  #      full y-span (turns two parallel arrows into one shared rail).
  #   2. Two-column "jog" — the trunk drops in one column for the
  #      upper half of the y-span, hops horizontally through a
  #      row-gap, then continues in a second column. This is what the
  #      user means by "join other arrows going in the same direction
  #      with a small detour" — each column can be a sibling's lane.
  #
  # Both candidates respect the connector type's directional valid
  # range (east of both endpoints for FF/SF, between for FS, west of
  # both for SS). Falls back to leaving the piercing alone if neither
  # repair is possible.
  defp consolidate_piercing_trunks(paths, ctx) do
    forwards =
      paths
      |> Enum.with_index()
      |> Enum.flat_map(fn {p, i} ->
        case PathFormat.parse(p.d) do
          %{kind: :forward, x1: x1, y1: y1, mid: mid, y2: y2, arrow_stop: stop} ->
            [{i, %{path: p, x1: x1, y1: y1, mid: mid, y2: y2, arrow_stop: stop}}]

          _ ->
            []
        end
      end)

    candidate_trunks = forwards |> Enum.map(fn {_, f} -> f.mid end) |> Enum.uniq()
    row_px = Map.get(ctx, :row_px, 40)

    rewrites =
      forwards
      |> Enum.flat_map(fn {idx, f} ->
        exclude = exclude_ids_for(paths, idx)
        bars_in_span = bars_crossing_span(ctx.bars, f.y1, f.y2, exclude)

        if trunk_collides?(f.mid, bars_in_span) do
          {min_x, max_x} = valid_range_for_type(f, paths, idx)
          in_range = fn x -> x >= min_x and x <= max_x end

          # Pass 1: full-span clean column (single mid_x for the whole trunk).
          full_clean =
            candidate_trunks
            |> Enum.reject(&(&1 == f.mid))
            |> Enum.filter(in_range)
            |> Enum.filter(fn x -> not trunk_collides?(x, bars_in_span) end)
            |> Enum.min_by(fn x -> abs(x - f.mid) end, fn -> nil end)

          cond do
            full_clean ->
              [{idx, rewrite_forward(f, full_clean)}]

            true ->
              # Pass 2: greedy N-segment walker — start at preferred
              # column, walk down the y-span row by row, and whenever
              # the current column hits a bar, hop horizontally
              # through the row gap above it onto another clean
              # column. Can chain many switches.
              case find_multi_segment_jog(f, candidate_trunks, ctx, exclude, in_range, row_px) do
                nil -> []
                segments -> [{idx, rewrite_forward_segments(f, segments)}]
              end
          end
        else
          []
        end
      end)
      |> Map.new()

    paths
    |> Enum.with_index()
    |> Enum.map(fn {p, i} -> Map.get(rewrites, i, p) end)
  end

  # Greedy multi-segment walker. Walks down from y1 to y2 in column
  # `current_x`, and whenever the current column hits a bar, hops
  # horizontally to another clean column at the row-gap ABOVE the
  # blocking bar. Returns a list `[{x_i, switch_y_i}, ...]` where
  # x_i is the column used until switch_y_i. Last element's
  # switch_y is y2.
  defp find_multi_segment_jog(f, candidate_trunks, ctx, exclude, in_range_fn, row_px) do
    valid_xs = candidate_trunks |> Enum.filter(in_range_fn) |> Enum.uniq() |> Enum.sort()
    {y_top, y_bot} = if f.y1 < f.y2, do: {f.y1, f.y2}, else: {f.y2, f.y1}

    walk_segments(f.mid, y_top, y_bot, valid_xs, ctx, exclude, row_px, [], 0)
  end

  # `max_hops` caps how many column changes we'll attempt — pathological
  # layouts could otherwise spin forever, and visually more than 3-4
  # zigzags looks worse than just piercing.
  @max_jog_hops 5

  defp walk_segments(_current_x, y_at, y_bot, _valid_xs, _ctx, _exclude, _row_px, _acc, hops)
       when hops > @max_jog_hops and y_at < y_bot do
    nil
  end

  defp walk_segments(current_x, y_at, y_bot, valid_xs, ctx, exclude, row_px, acc, hops) do
    bars_below = bars_crossing_span(ctx.bars, y_at, y_bot, exclude)
    first_blocker = first_blocking_bar(current_x, bars_below)

    cond do
      is_nil(first_blocker) ->
        # Clean to the end — emit final segment and stop.
        Enum.reverse([{current_x, y_bot} | acc])

      true ->
        # Switch column at the row-gap above the blocker.
        switch_y = first_blocker.y_top - 2

        if switch_y <= y_at do
          # No room to switch — give up.
          nil
        else
          remaining_bars = bars_crossing_span(ctx.bars, switch_y, y_bot, exclude)

          # Need a column that is clean from switch_y..y_bot AND
          # has a clear horizontal jog at switch_y from current_x.
          next_x =
            valid_xs
            |> Enum.reject(&(&1 == current_x))
            |> Enum.filter(fn x -> not trunk_collides?(x, remaining_bars) end)
            |> Enum.filter(fn x -> jog_clear?(current_x, x, switch_y, ctx.bars, exclude) end)
            # Prefer the column closest to current_x so the jog is small.
            |> Enum.min_by(fn x -> abs(x - current_x) end, fn -> nil end)

          if next_x do
            walk_segments(
              next_x,
              switch_y,
              y_bot,
              valid_xs,
              ctx,
              exclude,
              row_px,
              [{current_x, switch_y} | acc],
              hops + 1
            )
          else
            # No clean column for the remainder; settle for partial
            # routing and let the original piercing finish the path.
            # Currently we just bail — but a deeper search could try
            # different switch_ys here.
            nil
          end
        end
    end
  end

  # First bar (in y order) at column `x` that the trunk would pierce.
  defp first_blocking_bar(x, bars) do
    bars
    |> Enum.filter(fn b -> b.x_left < x and x < b.x_right end)
    |> Enum.min_by(& &1.y_top, fn -> nil end)
  end

  # True iff the horizontal jog at y=`switch_y` from x_a..x_b doesn't
  # pass through any bar's box (with a 1px tolerance).
  defp jog_clear?(x_a, x_b, switch_y, bars, exclude) do
    {x_lo, x_hi} = if x_a < x_b, do: {x_a, x_b}, else: {x_b, x_a}

    not Enum.any?(bars, fn b ->
      not MapSet.member?(exclude, b.event_id) and
        b.x_left < x_hi and b.x_right > x_lo and
        b.y_top < switch_y + 1 and b.y_bottom > switch_y - 1
    end)
  end

  # Re-emit the path as an N-segment polyline:
  #   M x1 y1 H seg1_x V seg1_y H seg2_x V seg2_y ... H stop V y2 H stop
  # Built directly here since PathFormat only owns 3- and 5-segment
  # forms; this is a multi-hop shape only used by the consolidator.
  defp rewrite_forward_segments(%{path: p, x1: x1, y1: y1, y2: _y2, arrow_stop: stop}, segments) do
    # Each segment is {column_x, end_y_of_that_column}. The last
    # segment's end_y is y2.
    middle =
      segments
      |> Enum.map(fn {x, y} -> "H #{x} V #{y}" end)
      |> Enum.join(" ")

    final_x = segments |> List.last() |> elem(0)
    d = "M #{x1} #{y1} #{middle} H #{stop}"

    %{p | d: d, label_x: final_x}
  end

  # `from_id` / `to_id` for an already-emitted path live on the path
  # map; use them to build the same exclude-set the original routing
  # used (source + target).
  defp exclude_ids_for(paths, idx) do
    case Enum.at(paths, idx) do
      %{from_id: from, to_id: to} -> MapSet.new([from, to])
      _ -> MapSet.new()
    end
  end

  # Look up the connector type on the original path so we can pick the
  # valid x-range for the sibling search. The type determines which
  # side of each bar the arrow exits/enters, so a sibling x WEST of
  # an FF arrow's east-east endpoints would force a 180° loop.
  defp valid_range_for_type(f, paths, idx) do
    type = paths |> Enum.at(idx) |> Map.get(:type, :fs)
    {src_exit, tgt_entry} = exit_entry_for(type)
    mid_valid_range(f.x1, f.arrow_stop, src_exit, tgt_entry)
  end

  defp exit_entry_for(:fs), do: {:east, :west}
  defp exit_entry_for(:ss), do: {:west, :west}
  defp exit_entry_for(:ff), do: {:east, :east}
  defp exit_entry_for(:sf), do: {:west, :east}
  defp exit_entry_for(_), do: {:east, :west}

  # Rebuild a forward path map with a new mid x. The `d` string and
  # any cached trunk label position get re-derived; everything else
  # carries through.
  defp rewrite_forward(%{path: p} = f, new_mid) do
    %{p | d: PathFormat.forward(f.x1, f.y1, new_mid, f.y2, f.arrow_stop), label_x: new_mid}
  end

  defp connector_path(conn, ctx) do
    from_event = Map.get(ctx.events_by_id, conn.from)
    to_event = Map.get(ctx.events_by_id, conn.to)
    from_pos = Map.get(ctx.row_positions.positions, conn.from)
    to_pos = Map.get(ctx.row_positions.positions, conn.to)

    if from_event && to_event && from_pos && to_pos do
      conn_key = {conn.from, conn.to, conn.type}
      {src_lane, src_bus_size} = Map.get(ctx.bus_lanes.source, conn_key, {0, 1})
      {tgt_lane, tgt_bus_size} = Map.get(ctx.bus_lanes.target, conn_key, {0, 1})

      geom = %{
        source_fanout: Map.get(ctx.outgoing_count, {conn.from, conn.type}, 1),
        target_fanin: Map.get(ctx.incoming_count, {conn.to, conn.type}, 1),
        lane: Map.get(ctx.backward_lanes, conn_key, 0),
        source_lane: src_lane,
        source_bus_size: src_bus_size,
        target_lane: tgt_lane,
        target_bus_size: tgt_bus_size,
        from_event: from_event,
        to_event: to_event,
        from_pos: from_pos,
        to_pos: to_pos
      }

      build_path(conn, geom, ctx)
    end
  end

  # Counts are keyed by {event_id, type} so a source with mixed-type
  # outgoing arrows doesn't produce false bus collapsing across types —
  # the :fs and :ss arrows from the same task leave different edges of
  # the bar, so they should not share trunks.
  defp count_connector_endpoints(connectors) do
    Enum.reduce(connectors, {%{}, %{}}, fn conn, {out_acc, in_acc} ->
      {
        Map.update(out_acc, {conn.from, conn.type}, 1, &(&1 + 1)),
        Map.update(in_acc, {conn.to, conn.type}, 1, &(&1 + 1))
      }
    end)
  end

  # Per-{event_id, side} tally of arrows by attach class.
  # Keys: {event_id, :east | :west}.
  # Values: %{out_up: int, in_above: int, in_below: int, out_down: int}
  # The "above/below" / "up/down" axis is determined by comparing the row
  # positions of the two endpoints. Used by smart-mode `attach_y/5` to
  # decide which of 4 designated y positions to use, and to collapse to
  # bar center when only one class is present on a side.
  defp count_per_side(connectors, row_positions) do
    Enum.reduce(connectors, %{}, fn conn, acc ->
      src_pos = Map.get(row_positions.positions, conn.from)
      tgt_pos = Map.get(row_positions.positions, conn.to)

      if src_pos && tgt_pos do
        src_side = source_side_for(conn.type)
        tgt_side = target_side_for(conn.type)

        # Same-row connectors are degenerate. Treat them as :down/:above by
        # convention (`>=` and `<=`) so the classification is deterministic.
        src_class = if tgt_pos.top >= src_pos.top, do: :out_down, else: :out_up
        tgt_class = if src_pos.top <= tgt_pos.top, do: :in_above, else: :in_below

        acc
        |> bump_attach({conn.from, src_side}, src_class)
        |> bump_attach({conn.to, tgt_side}, tgt_class)
      else
        acc
      end
    end)
  end

  @empty_attach_tally %{out_up: 0, in_above: 0, in_below: 0, out_down: 0}

  defp bump_attach(acc, key, attach_class) do
    Map.update(
      acc,
      key,
      Map.put(@empty_attach_tally, attach_class, 1),
      &Map.update(&1, attach_class, 1, fn n -> n + 1 end)
    )
  end

  # Classify a connector end. Mirrors `count_per_side/2`'s logic so the
  # attach class computed here lines up with the tallied class.
  defp source_attach_class(from_pos, to_pos) do
    if to_pos.top >= from_pos.top, do: :out_down, else: :out_up
  end

  defp target_attach_class(from_pos, to_pos) do
    if from_pos.top <= to_pos.top, do: :in_above, else: :in_below
  end

  # Static type → exit/entry side mapping, mirrors `endpoints_for/5`.
  defp source_side_for(:fs), do: :east
  defp source_side_for(:ff), do: :east
  defp source_side_for(:ss), do: :west
  defp source_side_for(:sf), do: :west

  defp target_side_for(:fs), do: :west
  defp target_side_for(:ss), do: :west
  defp target_side_for(:ff), do: :east
  defp target_side_for(:sf), do: :east

  # Vertical attachment point on a bar's edge. Falls back to row center in
  # three cases:
  # Compute the y where an arrow attaches to a bar's edge. Dispatches on
  # the configured `bus_attach_mode` (per-task `extra.bus_attach_mode`
  # overrides component-level setting). Always returns row center for
  # milestones (16px diamonds have no meaningful split point).
  defp attach_y(pos, event, side, attach_class, ctx) do
    if milestone?(event) do
      pos.center
    else
      mode = resolve_attach_mode(event, ctx)
      do_attach_y(mode, pos, event, side, attach_class, ctx)
    end
  end

  defp resolve_attach_mode(event, ctx) do
    case event.extra do
      %{bus_attach_mode: m} when m in [:smart, :type_zoned, :center] -> m
      _ -> ctx.bus_attach_mode
    end
  end

  # `:center` — never split; legacy behaviour.
  defp do_attach_y(:center, pos, _event, _side, _attach_class, _ctx), do: pos.center

  # `:smart` — two positions per side, picked by aggregate direction:
  #   1. Count this side's outgoing arrows by where the OTHER end sits
  #      (out_up vs out_down). The majority decides outgoing's region:
  #      most going down → outgoing at bar bottom; most going up → top.
  #      Ties pick bottom (matches the typical Gantt direction).
  #   2. Incoming takes the OPPOSITE region. This auto-resolves the
  #      ambiguous case where outgoing and incoming would otherwise want
  #      the same region (e.g., out_up + in_above on the same side).
  #   3. Side has only one direction (only out OR only in) → collapse to
  #      row center, since there's no other group to disambiguate from.
  # Both positions use `bus_attach_inner_pct` (default 40 → 40%/60% split).
  defp do_attach_y(:smart, pos, event, side, attach_class, ctx) do
    tally = Map.get(ctx.side_tally, {event.id, side}, @empty_attach_tally)
    out_count = tally.out_up + tally.out_down
    in_count = tally.in_above + tally.in_below

    cond do
      in_count == 0 or out_count == 0 ->
        pos.center

      true ->
        outgoing_at_bottom? = tally.out_down >= tally.out_up

        direction =
          if attach_class in [:out_up, :out_down], do: :outgoing, else: :incoming

        at_bottom? =
          case direction do
            :outgoing -> outgoing_at_bottom?
            :incoming -> not outgoing_at_bottom?
          end

        if at_bottom?,
          do: bar_bottom_attach(pos, ctx),
          else: bar_top_attach(pos, ctx)
    end
  end

  # `:type_zoned` — backwards-compatible behaviour: outgoing rides the
  # upper region of the bar, incoming the lower, regardless of the
  # OTHER end's row position. Uses `bus_split_offset_pct`.
  defp do_attach_y(:type_zoned, pos, event, side, attach_class, ctx) do
    tally = Map.get(ctx.side_tally, {event.id, side}, @empty_attach_tally)
    out_count = tally.out_up + tally.out_down
    in_count = tally.in_above + tally.in_below

    if in_count > 0 and out_count > 0 do
      direction = if attach_class in [:out_up, :out_down], do: :outgoing, else: :incoming
      split_attach_y(pos, direction, ctx.row_px, ctx.bus_split_offset_pct)
    else
      pos.center
    end
  end

  # Bar's upper-region attach point (used by smart mode when this side's
  # outgoing/incoming should sit toward the top of the bar).
  # Both helpers use `bus_attach_inner_pct` so smart mode has exactly two
  # positions per side (default 40%/60%).
  defp bar_top_attach(pos, ctx) do
    bar_top = pos.top + 4
    bar_height = max(ctx.row_px - 8, 8)
    bar_top + div(bar_height * ctx.bus_attach_inner_pct, 100)
  end

  defp bar_bottom_attach(pos, ctx) do
    bar_top = pos.top + 4
    bar_height = max(ctx.row_px - 8, 8)
    bar_top + bar_height - div(bar_height * ctx.bus_attach_inner_pct, 100)
  end

  # Type-zoned split. Bar inset: top-1 bottom-1 (Tailwind) = 4px each →
  # bar height = row_px - 8. `offset_pct` is the offset from the bar's
  # top edge for outgoing; incoming mirrors from the bottom.
  defp split_attach_y(pos, :outgoing, row_px, offset_pct) do
    bar_top = pos.top + 4
    bar_height = max(row_px - 8, 8)
    bar_top + div(bar_height * offset_pct, 100)
  end

  defp split_attach_y(pos, :incoming, row_px, offset_pct) do
    bar_top = pos.top + 4
    bar_height = max(row_px - 8, 8)
    bar_top + bar_height - div(bar_height * offset_pct, 100)
  end

  defp build_path(conn, geom, ctx) do
    %{
      x1: x1,
      arrow_stop: arrow_stop,
      source_exit: source_exit,
      target_entry: target_entry,
      backward: backward?
    } =
      endpoints_for(
        conn.type,
        geom.from_event,
        geom.to_event,
        ctx.view,
        ctx.day_px,
        ctx.min_bar_px
      )

    # Per-end attachment y. Three cases:
    # 1. Stagger active AND multiple arrows on this bus → distribute
    #    lanes evenly across the bar's flat region (excluding rounded
    #    corners), so each arrow emerges at a unique point INSIDE the
    #    bar's visible area (no mid-air emergence at a corner).
    # 2. Otherwise → use the smart-mode attach (out_down/in_above/etc.)
    #    or `:type_zoned` / `:center` depending on `bus_attach_mode`.
    # Milestones always use row center regardless.
    src_class = source_attach_class(geom.from_pos, geom.to_pos)
    tgt_class = target_attach_class(geom.from_pos, geom.to_pos)
    y1 = compute_attach_y(:source, geom, source_exit, src_class, ctx)
    y2 = compute_attach_y(:target, geom, target_entry, tgt_class, ctx)

    label_w = estimate_label_width(conn.label)
    style = resolve_style(conn, backward?, ctx.style_defaults)

    route = build_route(conn, source_exit, target_entry, label_w, geom, ctx)

    # Routing ctx folds per-connector overrides (avoid_collisions,
    # line margin) onto the ambient ctx, so downstream helpers read
    # the effective value without threading them as extra args.
    routing_ctx =
      ctx
      |> Map.put(:avoid_collisions, route.avoid_collisions)
      |> Map.put(:line_margin, route.bar_clearance)
      |> Map.put(:target_row_top, geom.to_pos.top)

    # Decide forward vs detour. Heuristic + collision-fallback:
    #   1. Tight gap or label-doesn't-fit (existing `use_detour?`)
    #   2. (NEW) For :fs forward, check if the trunk's preferred x can
    #      actually avoid all intermediate bars. If not, force detour —
    #      its routing-via-row-border avoids the bars entirely.
    fs_detour? =
      use_detour?(conn, x1, arrow_stop, backward?, label_w) or
        forward_path_unfeasible?(conn, x1, y1, arrow_stop, y2, geom, route, routing_ctx)

    {d, label_x, label_y, label_transform} =
      if fs_detour? do
        build_fs_detour_path(x1, y1, arrow_stop, y2, geom, routing_ctx, route)
      else
        build_forward_path(x1, y1, arrow_stop, y2, geom, routing_ctx, route)
      end

    %{
      d: d,
      from_id: geom.from_event.id,
      to_id: geom.to_event.id,
      type: conn.type,
      critical: conn.critical,
      invalid: backward?,
      label: conn.label,
      label_x: label_x,
      label_y: label_y,
      label_width: label_w,
      label_transform: label_transform,
      color_class: style.color_class,
      stroke_width: style.stroke_width,
      opacity: style.opacity,
      dasharray: style.dasharray,
      # Whether the TARGET is a milestone diamond — `finalize_arrowhead/1` uses
      # it to nudge the head off the diamond's centre to its edge.
      target_milestone: milestone?(geom.to_event),
      # Placeholder — recomputed from the FINAL `d` by `finalize_arrowhead/1`
      # after path rewrites. Present here so the map has the key to update.
      arrow: nil
    }
  end

  # The arrowhead is drawn in a SEPARATE, non-stretched overlay layer (see the
  # render) — positioned by % (so its tip tracks the bar-aligned path end as the
  # chart fills/scrolls) but sized in fixed px (so it stays a crisp triangle
  # instead of stretching with the horizontal fill factor). A stretched line is
  # still a correct line, so the SHAFT can live in the %-stretched SVG; a
  # stretched triangle is not an arrowhead, so the HEAD can't.
  #
  # Reduce a (post-rewrite) M/H/V path `d` to its arrowhead anchor: the last
  # point and the direction of the final segment. Every shape family — the
  # 3-seg forward, 5-seg detour, and the consolidator's N-seg jog — ends in a
  # horizontal "H stop", so the head points east (→) or west (←); anything else
  # collapses to east. Reading the actual final `d` (rather than the pre-rewrite
  # endpoints) keeps the head on the shaft's true end even when
  # `consolidate_piercing_trunks` re-routes it.
  defp arrowhead_from_d(d) do
    %{x: tip_x, y: tip_y, dir: dir} = PathFormat.terminal(d)
    {tip_x, tip_y, if(dir == :west, do: :west, else: :east)}
  end

  # Precompute everything the overlay needs: the tip anchor (tip_x in px →
  # rendered as % of content width; tip_y in px, vertically un-stretched), the
  # fixed px triangle `d`, and the px nudge that lands the triangle's tip on the
  # anchor. Critical arrows are a touch larger, matching the old marker sizing.
  # Half-diagonal of the default `w-4` (16px) milestone diamond, plus a hair —
  # how far OUTSIDE the diamond's centre its near point sits. The shaft attaches
  # at the centre (covered by the z-40 diamond), but the fixed-px arrowhead is
  # nudged out to here so it reads as pointing AT the diamond, not buried in it.
  @milestone_edge_px 12

  defp arrowhead_geometry(tip_x, tip_y, dir, variant, target_milestone?) do
    size = if variant == :critical, do: 10, else: 8
    half = div(size, 2)

    # Triangle drawn in a 0..size box; tip on the side it points toward, then the
    # svg is offset so that tip coincides with the (tip_x, tip_y) anchor.
    {d, base_off_x} =
      case dir do
        :east -> {"M 0 0 L #{size} #{half} L 0 #{size} z", -size}
        :west -> {"M #{size} 0 L 0 #{half} L #{size} #{size} z", 0}
      end

    # The container stays anchored on the shaft end (`tip_x`), but for a milestone
    # target we shift the drawn triangle OUT to the diamond's edge via the svg
    # offset (a fixed px, so it clears the fixed-px diamond at any fill). The
    # anchor staying on the shaft end keeps the head-meets-shaft invariant valid;
    # only the visible triangle moves.
    nudge =
      cond do
        not target_milestone? -> 0
        dir == :east -> -@milestone_edge_px
        true -> @milestone_edge_px
      end

    %{
      tip_x: tip_x,
      tip_y: tip_y,
      size: size,
      d: d,
      off_x: base_off_x + nudge,
      off_y: -half,
      variant_class: arrowhead_variant_class(variant)
    }
  end

  # Keep the legacy `lg-arrow{,-invalid,-critical}` tokens so styling hooks and
  # tests that keyed on the old marker ids still match.
  defp arrowhead_variant_class(:invalid), do: "lg-arrow-invalid"
  defp arrowhead_variant_class(:critical), do: "lg-arrow-critical"
  defp arrowhead_variant_class(:normal), do: "lg-arrow"

  # Bundle source/target endpoint info with per-connector routing
  # overrides (or fallbacks to ctx defaults) so individual builders see
  # a flat map rather than reaching into conn/ctx for every knob.
  defp build_route(conn, source_exit, target_entry, label_w, geom, ctx) do
    %{
      exclude_ids: MapSet.new([geom.from_event.id, geom.to_event.id]),
      source_exit: source_exit,
      target_entry: target_entry,
      label_width: label_w,
      label_orientation: conn.label_orientation,
      exit_stem: conn.exit_stem || ctx.elbow_px,
      entry_stem: conn.entry_stem || ctx.elbow_px,
      detour_side: conn.detour_side,
      bar_clearance: conn.bar_clearance || ctx.bar_clearance_px,
      avoid_collisions: resolve_bool(conn.avoid_collisions, ctx.avoid_collisions)
    }
  end

  # Decide whether to render as a 5-segment detour or a 3-segment
  # direct. Per-connector `shape` overrides the auto heuristic:
  #   :direct — never detour (except backward, which has no coherent
  #             3-seg shape and must detour regardless)
  #   :detour — always detour, even with a wide gap
  #   :auto   — detour only when the gap is too tight for clean stems
  #             or the label doesn't fit between the bars
  defp use_detour?(%{type: :fs, shape: :direct}, _x1, _arrow_stop, backward?, _label_w),
    do: backward?

  defp use_detour?(%{type: :fs, shape: :detour}, _x1, _arrow_stop, _backward?, _label_w), do: true

  defp use_detour?(%{type: :fs}, x1, arrow_stop, backward?, label_w),
    do: backward? or forward_fs_needs_detour?(x1, arrow_stop, label_w)

  defp use_detour?(_conn, _x1, _arrow_stop, _backward?, _label_w), do: false

  # True when the forward 3-seg path can't place its trunk x without
  # piercing an intermediate bar. Only applies to :fs (other types have
  # different shape families and either don't have intermediate bars in
  # their trunk's y span, or accept piercing as a known limit). When
  # `avoid_collisions` is off or the connector isn't :fs, returns false
  # (let the existing logic run).
  #
  # Used by `build_path/3` to fall back from forward to detour when the
  # forward path is geometrically blocked. The detour path routes via the
  # row border (just past source's row top/bottom) which slips through
  # the gap between bars regardless of x.
  defp forward_path_unfeasible?(%{type: :fs}, x1, y1, arrow_stop, y2, geom, route, ctx) do
    if not Map.get(ctx, :avoid_collisions, true) do
      false
    else
      elbow = Map.get(route, :exit_stem, @elbow_px)

      base_mid =
        choose_mid_x(
          x1,
          arrow_stop,
          route.source_exit,
          route.target_entry,
          geom.source_fanout,
          geom.target_fanin,
          Map.get(route, :label_width, 0),
          elbow
        )

      preferred_mid = base_mid + forward_stagger_offset(geom, route, ctx)
      {min_x, max_x} = mid_valid_range(x1, arrow_stop, route.source_exit, route.target_entry)

      bars_in_span = bars_crossing_span(ctx.bars, y1, y2, route.exclude_ids)

      cond do
        bars_in_span == [] ->
          false

        preferred_mid >= min_x and preferred_mid <= max_x and
            not trunk_collides?(preferred_mid, bars_in_span) ->
          false

        true ->
          # If any candidate (bar edge ± 3) within valid_range gives a
          # clean trunk, forward is feasible (maybe_shift_trunk will
          # take it). Otherwise force detour.
          clean_exists? =
            preferred_mid
            |> candidate_xs(bars_in_span)
            |> Enum.any?(fn x ->
              x >= min_x and x <= max_x and not trunk_collides?(x, bars_in_span)
            end)

          not clean_exists?
      end
    end
  end

  defp forward_path_unfeasible?(_conn, _x1, _y1, _arrow_stop, _y2, _geom, _route, _ctx),
    do: false

  # Merge per-connector style overrides (nil = inherit) onto the
  # category defaults (normal / critical / invalid).
  defp resolve_style(conn, invalid?, defaults) do
    category =
      cond do
        invalid? -> defaults.invalid
        conn.critical -> defaults.critical
        true -> defaults.normal
      end

    %{
      color_class: conn.color_class || category.color_class,
      stroke_width: conn.stroke_width || category.stroke_width,
      opacity: conn.opacity || category.opacity,
      dasharray: conn.dasharray || category.dasharray
    }
  end

  defp resolve_bool(nil, default), do: default
  defp resolve_bool(value, _default), do: value

  defp estimate_label_width(nil), do: 0
  defp estimate_label_width(""), do: 0

  defp estimate_label_width(label) when is_binary(label),
    do: String.length(label) * @label_char_px

  # Slide the label along its segment (a horizontal leg for detours, a
  # vertical trunk otherwise) until its rect doesn't overlap any
  # non-excluded bar. Candidate positions start at the segment center
  # and expand outward in 6px steps; the first clear candidate wins.
  # If nothing is clear, falls back to the segment center.
  #
  # `route.label_orientation` (:horizontal | :vertical) controls whether
  # the label renders rotated -90°; rotation swaps which axis the rect's
  # long edge sits along, which changes the bbox used for overlap checks.
  defp place_label(%{kind: kind, fixed: fixed, min: seg_min, max: seg_max}, route, ctx) do
    label_w = Map.get(route, :label_width, 0)

    if label_w == 0 do
      center = div(seg_min + seg_max, 2)
      {x, y} = materialize_position(kind, fixed, center)
      {x, y, nil}
    else
      orientation = Map.get(route, :label_orientation, :horizontal)
      {bbox_along, bbox_perp} = label_bbox(label_w, kind, orientation)
      half_along = div(bbox_along, 2)
      half_perp = div(bbox_perp, 2)

      center = div(seg_min + seg_max, 2)
      slide_min = seg_min + half_along
      slide_max = seg_max - half_along

      candidates =
        [center] ++
          for step <- 1..15, offset = step * 6, pos <- [center + offset, center - offset] do
            pos
          end

      feasible =
        Enum.filter(candidates, fn pos -> pos >= slide_min and pos <= slide_max end)

      clear =
        Enum.find(feasible, fn pos ->
          {x, y} = materialize_position(kind, fixed, pos)

          not label_overlaps_any_bar?(x, y, half_along, half_perp, kind, ctx, route.exclude_ids)
        end)

      chosen = clear || center
      {x, y} = materialize_position(kind, fixed, chosen)
      transform = if orientation == :vertical, do: "rotate(-90 #{x} #{y})", else: nil
      {x, y, transform}
    end
  end

  defp materialize_position(:horizontal, fixed_y, slide_x), do: {slide_x, fixed_y}
  defp materialize_position(:vertical, fixed_x, slide_y), do: {fixed_x, slide_y}

  # Returns {bbox_along_segment, bbox_perpendicular_to_segment} in px,
  # accounting for rotation. The text is ~label_w wide × ~10px tall;
  # add a few px of halo margin so placement gives the glyphs + stroke
  # halo a bit of breathing room off intermediate bars.
  defp label_bbox(label_w, :horizontal, :horizontal), do: {label_w + 4, 12}
  defp label_bbox(label_w, :horizontal, :vertical), do: {12, label_w + 4}
  defp label_bbox(label_w, :vertical, :horizontal), do: {12, label_w + 4}
  defp label_bbox(label_w, :vertical, :vertical), do: {label_w + 4, 12}

  defp label_overlaps_any_bar?(x, y, half_along, half_perp, kind, ctx, exclude_ids) do
    {x_min, x_max, y_min, y_max} =
      case kind do
        :horizontal -> {x - half_along, x + half_along, y - half_perp, y + half_perp}
        :vertical -> {x - half_perp, x + half_perp, y - half_along, y + half_along}
      end

    Enum.any?(ctx.bars, fn b ->
      not MapSet.member?(exclude_ids, b.event_id) and
        b.x_left < x_max and b.x_right > x_min and
        b.y_top < y_max and b.y_bottom > y_min
    end)
  end

  # `{left_px, right_px}` of an event's bar AS RENDERED (honoring `min_bar_px`),
  # so connector endpoints attach to the visible bar. A milestone collapses to
  # its center point (the ±10px diamond offset is applied by the caller).
  # Out-of-range falls back to raw temporal coords (the connector is typically
  # not drawn in that case anyway).
  defp rendered_edges(event, {origin, _span} = view, day_px, min_bar_px) do
    case bar_geometry(event, view, day_px, min_bar_px) do
      %{milestone: true, left_px: l} ->
        {l, l}

      %{left_px: l, width_px: w} ->
        {l, l + w}

      _ ->
        {x_px(event.start, origin, day_px),
         x_px(LiveGantt.Task.effective_end(event), origin, day_px)}
    end
  end

  defp endpoints_for(type, from_event, to_event, {origin, _span} = view, day_px, min_bar_px) do
    # Connectors attach at gap 0 — the bar's edge, or (for a milestone, where
    # `rendered_edges` collapses to the diamond's CENTER) the diamond center. A
    # bar edge reads as connected at any responsive fill because the shaft SVG
    # stretches in lockstep with the bars. We used to push a milestone's
    # endpoint out by a 10px "diamond clearance", but that 10px is in CONTENT
    # units that the fill STRETCHES — so against the FIXED-px diamond it became a
    # visible gap (the arrow stopping short of the diamond). Attaching at the
    # center instead lets the diamond (raised above the connector layer) sit
    # cleanly on the shaft end + arrowhead.

    # DRAW from the RENDERED bar edges (honoring `min_bar_px`), so a sub-pixel
    # task that renders wider than its true span still has its arrow attach to
    # the bar AS DRAWN rather than emerging from inside it.
    {from_start_px, from_end_px} = rendered_edges(from_event, view, day_px, min_bar_px)
    {to_start_px, to_end_px} = rendered_edges(to_event, view, day_px, min_bar_px)

    # JUDGE backward/invalid from the NATURAL temporal edges, NOT the rendered
    # ones — the conflict is about the schedule, not the min-width-inflated
    # render. (Otherwise a zero-gap FS dep — B starting exactly when A finishes —
    # is wrongly flagged backward because A's 1px sliver pokes past B's start.)
    # Origin is shared, so the relative comparison is unaffected by which it is.
    from_start_nat = x_px(from_event.start, origin, day_px)
    from_end_nat = x_px(LiveGantt.Task.effective_end(from_event), origin, day_px)
    to_start_nat = x_px(to_event.start, origin, day_px)
    to_end_nat = x_px(LiveGantt.Task.effective_end(to_event), origin, day_px)

    case type do
      :fs ->
        %{
          x1: from_end_px,
          arrow_stop: to_start_px,
          source_exit: :east,
          target_entry: :west,
          backward: conflict?(from_end_nat, to_start_nat)
        }

      :ss ->
        %{
          x1: from_start_px,
          arrow_stop: to_start_px,
          source_exit: :west,
          target_entry: :west,
          backward: conflict?(from_start_nat, to_start_nat)
        }

      :ff ->
        %{
          x1: from_end_px,
          arrow_stop: to_end_px,
          source_exit: :east,
          target_entry: :east,
          backward: conflict?(from_end_nat, to_end_nat)
        }

      :sf ->
        %{
          x1: from_start_px,
          arrow_stop: to_end_px,
          source_exit: :west,
          target_entry: :east,
          backward: conflict?(from_start_nat, to_end_nat)
        }
    end
  end

  # Schedule conflict (invalid / "time travel") — same rule for every
  # dep type: the constraint reference point on the target is earlier
  # in time than the reference point on the source.
  defp conflict?(x1, x2), do: x2 < x1

  # Forward (non-conflicting) path — always three segments. `mid_x` is
  # chosen per exit/entry combination plus bus-aware preferences:
  #
  #   many arrows from same source → trunk aligns on source+elbow
  #   many arrows into same target → trunk aligns on target+-elbow
  #
  # For FS with source and target crammed together (no room for a
  # clean three-segment), we fall back to the midpoint so the
  # visual kink is minimal rather than overshooting past target.
  #
  # When `avoid_collisions` is on, the chosen mid_x is shifted (within
  # its type-valid range) to dodge any unrelated bar the trunk would
  # otherwise pierce.
  defp build_forward_path(x1, y1, arrow_stop, y2, geom, ctx, route) do
    elbow = Map.get(route, :exit_stem, @elbow_px)

    base_mid =
      choose_mid_x(
        x1,
        arrow_stop,
        route.source_exit,
        route.target_entry,
        geom.source_fanout,
        geom.target_fanin,
        Map.get(route, :label_width, 0),
        elbow
      )

    # Stagger trunk x by lane offset when this arrow is part of a fan-out
    # bus with `bus_stagger_outgoing_px > 0` or fan-in bus with
    # `bus_stagger_incoming_px > 0`. No-op (offset=0) when stagger is off
    # or when this arrow isn't sharing a bus with siblings.
    preferred_mid = base_mid + forward_stagger_offset(geom, route, ctx)

    mid_x =
      maybe_shift_trunk(
        preferred_mid,
        y1,
        y2,
        mid_valid_range(x1, arrow_stop, route.source_exit, route.target_entry),
        route.exclude_ids,
        ctx
      )
      |> enforce_milestone_approach(arrow_stop, route.target_entry, milestone?(geom.to_event))

    d = PathFormat.forward(x1, y1, mid_x, y2, arrow_stop)

    # Label lives on the vertical trunk — slide along y to find a clear
    # position if the center would overlap a bar.
    segment = %{
      kind: :vertical,
      fixed: mid_x,
      min: min(y1, y2),
      max: max(y1, y2)
    }

    {label_x, label_y, label_transform} = place_label(segment, route, ctx)
    {d, label_x, label_y, label_transform}
  end

  # A milestone target's arrowhead is nudged @milestone_edge_px out along the
  # final approach segment (the last `H arrow_stop` leg), so that leg must be at
  # least that long (+2px margin) or the fixed-px head lands off the shaft at a
  # low fill factor. Push the trunk away from the target on the entry side. This
  # is the forward-path twin of `build_fs_detour_path`'s `base_entry` floor; it
  # covers all four dep types (entry is :west for FS/SS, :east for FF/SF) and any
  # `fanin`/`fanout` preference that would otherwise hug the target.
  defp enforce_milestone_approach(mid, _arrow_stop, _entry, false), do: mid

  defp enforce_milestone_approach(mid, arrow_stop, :west, true),
    do: min(mid, arrow_stop - (@milestone_edge_px + 2))

  defp enforce_milestone_approach(mid, arrow_stop, :east, true),
    do: max(mid, arrow_stop + (@milestone_edge_px + 2))

  defp choose_mid_x(x1, arrow_stop, :east, :west, fanout, fanin, _label_w, elbow) do
    # FS — stems point at each other; trunk lives BETWEEN them.
    #
    # Clearance constraints (enforced via clamp below):
    #   mid_x ≥ x1 + @min_exit_stem_px   — visible exit stem at source
    #   mid_x ≤ arrow_stop - @min_approach_px — arrow marker clears trunk
    #
    # This branch only runs when the gap is wide enough for both
    # minimums — tight gaps are routed via `build_fs_detour_path` in
    # `build_path`, so no degenerate-fallback case is needed here.
    min_mid = x1 + @min_exit_stem_px
    max_mid = arrow_stop - @min_approach_px

    preferred =
      cond do
        fanout > 1 -> x1 + elbow
        fanin > 1 -> arrow_stop - elbow
        true -> div(x1 + arrow_stop, 2)
      end

    preferred |> max(min_mid) |> min(max_mid)
  end

  defp choose_mid_x(x1, arrow_stop, :west, :west, fanout, fanin, label_w, elbow) do
    # SS — both stems exit west; trunk sits west of the earliest of
    # the two. Labels ride the vertical trunk, so when present we push
    # the offset further west by label_half + clearance to keep the
    # label out of the source/target bar x-range.
    offset = label_aware_offset(label_w, elbow)
    stem_out = x1 - offset
    stem_in = arrow_stop - offset

    cond do
      fanout > 1 -> stem_out
      fanin > 1 -> stem_in
      true -> min(stem_out, stem_in)
    end
  end

  defp choose_mid_x(x1, arrow_stop, :east, :east, fanout, fanin, label_w, elbow) do
    # FF — both stems exit east; trunk sits east of the latest of
    # the two. Label pushes trunk further east.
    offset = label_aware_offset(label_w, elbow)
    stem_out = x1 + offset
    stem_in = arrow_stop + offset

    cond do
      fanout > 1 -> stem_out
      fanin > 1 -> stem_in
      true -> max(stem_out, stem_in)
    end
  end

  defp choose_mid_x(x1, arrow_stop, :west, :east, fanout, fanin, label_w, elbow) do
    # SF — source exits west, target enters from east. Routing around
    # the right side (east of target_end) keeps the arrow tangent
    # aligned with the target_entry direction. Trunk sits east of
    # target; push further east for label.
    label_offset = label_aware_offset(label_w, elbow)
    stem_out = x1 - elbow
    stem_in = arrow_stop + label_offset

    cond do
      fanout > 1 -> stem_out
      fanin > 1 -> stem_in
      true -> max(stem_out, stem_in)
    end
  end

  # Offset for same-side trunks (SS/FF/SF). With no label, just the
  # elbow; with a label, at least half the label width plus clearance
  # so the trunk-centered label clears the nearest bar edge.
  defp label_aware_offset(0, elbow), do: elbow
  defp label_aware_offset(label_w, elbow), do: max(elbow, div(label_w, 2) + @label_clearance_px)

  # When to use the detour instead of the straight 3-segment:
  #
  #   * The gap between source-end-east-tip and target-approach-west
  #     must be at least a full exit stem + full approach stem, else
  #     the 3-segment would squish one side.
  #   * When the arrow carries a label, the gap must ALSO be wide
  #     enough for the label to sit between the bars on the vertical
  #     trunk without overlapping them. If not, switch to detour —
  #     the label then sits on the horizontal leg.
  defp forward_fs_needs_detour?(x1, arrow_stop, label_w) do
    gap = arrow_stop - x1
    base_min = @min_exit_stem_px + @min_approach_px

    label_min =
      if label_w > 0,
        do: label_w + @label_clearance_px * 2,
        else: 0

    gap < max(base_min, label_min)
  end

  # Five-segment FS detour — used when the 3-segment can't route cleanly.
  # Covers two cases with the SAME shape:
  #
  #   1. Backward (schedule conflict): target starts earlier than source
  #      ends; the forward stems would point into each other. Rendered
  #      as invalid (dashed red) elsewhere based on `conflict?`.
  #   2. Forward but tight: source and target are valid order but too
  #      close for the 3-segment to fit clean exit + approach stems.
  #      Still a normal (solid) arrow — just a richer shape.
  #
  # Shape: east stem out of source → vertical to row border → horizontal
  # across intermediate rows → vertical to target row → east stem into
  # target. Every segment advances toward the target for the forward
  # case; for backward some segments must retrace.
  #
  # `lane` staggers detour_y when multiple backward arrows share the
  # same source row and direction — otherwise they'd draw on top of
  # each other. Lane 0 sits exactly on the border; each subsequent
  # lane is 2px further into the adjacent row. Forward-tight arrows
  # get lane 0 (they're not in the backward-lanes map) so a tight-FS
  # bus stays visually merged.
  #
  # Collision avoidance: the final vertical at `stem_in` is the segment
  # most likely to cross unrelated bars. Rather than shifting stem_in
  # west (which makes the horizontal detour tail absurdly long), we
  # push `detour_y` TOWARD the target past any intermediate bar the
  # final vertical would otherwise pierce — i.e. the horizontal leg
  # routes *under* / *over* the obstruction instead of *across* it.
  defp build_fs_detour_path(x1, y1, arrow_stop, y2, geom, ctx, route) do
    # Stems default to the connector's exit/entry override (or the
    # component-level elbow). For labeled detours we widen symmetrically
    # so the leg's horizontal extent fits the label.
    label_w = Map.get(route, :label_width, 0)
    gap = arrow_stop - x1
    base_exit = Map.get(route, :exit_stem, @elbow_px)

    # A milestone target's arrowhead is nudged @milestone_edge_px OUT to the
    # diamond edge — a fixed SCREEN px. The head rides the final approach segment,
    # so that segment (in VIEWBOX px) must be at least that long, or at a low fill
    # factor (the `:min5` scroll case, where the approach renders ~1:1) the nudged
    # head overshoots the trunk and floats off, disconnected. Give a milestone
    # target an approach stem a hair longer than the nudge so the head always
    # lands ON the shaft, at every zoom. (Longer paths at a high fill are fine.)
    base_entry =
      if milestone?(geom.to_event) do
        max(Map.get(route, :entry_stem, @elbow_px), @milestone_edge_px + 2)
      else
        Map.get(route, :entry_stem, @elbow_px)
      end

    {exit_offset, entry_offset} =
      if label_w > 0 do
        needed = div(max(gap, 0) + label_w + @label_clearance_px * 2, 2)
        {max(base_exit, needed), max(base_entry, needed)}
      else
        {base_exit, base_entry}
      end

    # Stagger source/target stems independently — the detour shape has
    # two distinct x's, so source-side fan-out and target-side fan-in
    # stagger can both apply to the same arrow without conflicting.
    {src_stagger, tgt_stagger} = stagger_x_offsets(geom, route, ctx)

    stem_out = x1 + exit_offset + src_stagger
    stem_in = arrow_stop - entry_offset + tgt_stagger

    # Detour direction: `:auto` picks the natural side (same direction as
    # target); `:above` / `:below` force the detour above or below the
    # source row regardless of target position.
    forced_side = Map.get(route, :detour_side, :auto)

    # Use the source row's ACTUAL top/bottom border (not y1 ± row_px/2),
    # because Y stagger can offset y1 anywhere within the bar's height.
    # If we anchored detour_y to y1 + row_px/2 we'd push detour_y into
    # the NEXT row when y1 is at the source bar's bottom edge — and
    # stem_out's y span would then reach into intermediate bars.
    src_top = geom.from_pos.top
    src_bottom = src_top + ctx.row_px

    {detour_base, dir_sign} =
      case {forced_side, y2 > y1} do
        {:above, _} -> {src_top, -1}
        {:below, _} -> {src_bottom, 1}
        {_, true} -> {src_bottom, 1}
        {_, false} -> {src_top, -1}
      end

    preferred_detour_y = detour_base + dir_sign * geom.lane * 2

    # Compute the label bounding box BEFORE pushing, so the push can
    # account for it (keep the label rect out of obstructing bars too,
    # not just the line).
    leg_mid = div(stem_out + stem_in, 2)

    label_box =
      if label_w > 0 do
        half_w = div(label_w + 4, 2)

        %{
          x_min: leg_mid - half_w,
          x_max: leg_mid + half_w,
          half_height: 6
        }
      end

    detour_y =
      push_detour_past_obstructions(
        preferred_detour_y,
        stem_in,
        y2,
        dir_sign,
        ctx.row_px,
        route.exclude_ids,
        ctx,
        label_box
      )

    # After detour_y is fixed, stem_out's vertical span (y1 to detour_y)
    # may now reach into intermediate rows. If a bar at stem_out's x sits
    # in that span, the vertical line pierces it. Similarly stem_in's
    # vertical span (detour_y to y2). Shifting a stem extends the
    # horizontal leg, which may then pierce a bar at detour_y.
    #
    # The fixed point is: stems and detour_y consistent — neither stem
    # pierces a bar in its column-y-span, AND detour_y doesn't sit
    # inside any bar overlapping the leg's x range. Converge by
    # alternating shifts and pushes until stable.
    {stem_out, stem_in, detour_y} =
      converge_detour_geometry(
        stem_out,
        stem_in,
        detour_y,
        x1,
        y1,
        arrow_stop,
        y2,
        dir_sign,
        route,
        ctx
      )

    d = PathFormat.detour(x1, y1, stem_out, detour_y, stem_in, y2, arrow_stop)

    # Label lives on the horizontal detour leg — slide along x to find
    # a clear position if the center would overlap a bar.
    segment = %{
      kind: :horizontal,
      fixed: detour_y,
      min: min(stem_out, stem_in),
      max: max(stem_out, stem_in)
    }

    {label_x, label_y, label_transform} = place_label(segment, route, ctx)
    {d, label_x, label_y, label_transform}
  end

  # Precompute a lane index per backward FS connector so multiple arrows
  # with the same source row + direction don't stack on top of each
  # other. Returns a map keyed by `{from_id, to_id, type}` → integer.
  defp assign_backward_lanes(
         normalized_connectors,
         events_by_id,
         row_positions,
         view,
         day_px,
         min_bar_px
       ) do
    normalized_connectors
    |> Enum.filter(fn c ->
      from_event = Map.get(events_by_id, c.from)
      to_event = Map.get(events_by_id, c.to)
      from_pos = Map.get(row_positions.positions, c.from)
      to_pos = Map.get(row_positions.positions, c.to)

      cond do
        is_nil(from_event) or is_nil(to_event) ->
          false

        is_nil(from_pos) or is_nil(to_pos) ->
          false

        c.type != :fs ->
          false

        true ->
          %{backward: backward} =
            endpoints_for(c.type, from_event, to_event, view, day_px, min_bar_px)

          backward
      end
    end)
    |> Enum.group_by(fn c ->
      from_pos = row_positions.positions[c.from]
      to_pos = row_positions.positions[c.to]
      dir = if to_pos.center > from_pos.center, do: :down, else: :up
      {c.from, dir}
    end)
    |> Enum.flat_map(fn {_key, group} ->
      group
      |> Enum.with_index()
      |> Enum.map(fn {c, idx} -> {{c.from, c.to, c.type}, idx} end)
    end)
    |> Map.new()
  end

  # Precompute lane indices for FORWARD bus stagger. For each
  # `{event_id, side, :outgoing | :incoming}` bus, sort the connectors
  # in the bus by the OTHER end's row position so adjacent rows get
  # adjacent lanes (visually monotonic fanning). Returns:
  #
  #   %{
  #     source: %{conn_key => integer lane in source's outgoing bus},
  #     target: %{conn_key => integer lane in target's incoming bus}
  #   }
  #
  # `conn_key` = `{from_id, to_id, type}`. Both maps are looked up in
  # `connector_path/2` and stashed on `geom` so per-arrow path builders
  # can apply the stagger without re-walking the connector list.
  defp assign_bus_lanes(normalized_connectors, row_positions) do
    positions = row_positions.positions

    conn_data =
      normalized_connectors
      |> Enum.filter(fn c ->
        Map.has_key?(positions, c.from) and Map.has_key?(positions, c.to)
      end)
      |> Enum.map(fn c ->
        %{
          conn_key: {c.from, c.to, c.type},
          src_bus: {c.from, source_side_for(c.type), :outgoing},
          tgt_bus: {c.to, target_side_for(c.type), :incoming},
          src_pos: positions[c.from],
          tgt_pos: positions[c.to]
        }
      end)

    %{
      source: assign_lanes_for_bus(conn_data, :src_bus, :tgt_pos),
      target: assign_lanes_for_bus(conn_data, :tgt_bus, :src_pos)
    }
  end

  defp assign_lanes_for_bus(conn_data, bus_field, sort_pos_field) do
    conn_data
    |> Enum.group_by(&Map.get(&1, bus_field))
    |> Enum.flat_map(fn {_bus_key, members} ->
      bus_size = length(members)

      members
      |> Enum.sort_by(&Map.get(&1, sort_pos_field).top)
      |> Enum.with_index()
      |> Enum.map(fn {data, lane} -> {data.conn_key, {lane, bus_size}} end)
    end)
    |> Map.new()
  end

  # Returns `{source_offset, target_offset}` x-offsets for bus stagger.
  # Positive = east, negative = west. Each side's offset is independent:
  # source's outgoing-bus stagger affects the source-side stem; target's
  # incoming-bus stagger affects the target-side stem. The forward 3-seg
  # path has a single trunk x and uses whichever side is biased (matching
  # `choose_mid_x`'s fanout-wins precedence). The 5-seg detour path has
  # distinct stem_out and stem_in x's and applies both offsets.
  defp stagger_x_offsets(geom, route, ctx) do
    src_stagger = task_stagger(geom.from_event, :outgoing, ctx)
    tgt_stagger = task_stagger(geom.to_event, :incoming, ctx)

    source_offset =
      if geom.source_fanout > 1 and src_stagger > 0 do
        side_sign(route.source_exit) * geom.source_lane * src_stagger
      else
        0
      end

    target_offset =
      if geom.target_fanin > 1 and tgt_stagger > 0 do
        side_sign(route.target_entry) * geom.target_lane * tgt_stagger
      else
        0
      end

    {source_offset, target_offset}
  end

  # Pick the right stagger offset for the forward 3-seg path's single
  # trunk x. Mirrors `choose_mid_x`'s fanout-wins precedence: when source
  # has fan-out, trunk is biased toward source so the source-side stagger
  # applies; otherwise the target-side stagger applies.
  defp forward_stagger_offset(geom, route, ctx) do
    {src_off, tgt_off} = stagger_x_offsets(geom, route, ctx)

    cond do
      geom.source_fanout > 1 -> src_off
      geom.target_fanin > 1 -> tgt_off
      true -> 0
    end
  end

  defp task_stagger(event, :outgoing, ctx) do
    case event.extra do
      %{bus_stagger_outgoing_px: n} when is_integer(n) and n >= 0 -> n
      _ -> ctx.bus_stagger_outgoing_px
    end
  end

  defp task_stagger(event, :incoming, ctx) do
    case event.extra do
      %{bus_stagger_incoming_px: n} when is_integer(n) and n >= 0 -> n
      _ -> ctx.bus_stagger_incoming_px
    end
  end

  defp side_sign(:east), do: 1
  defp side_sign(:west), do: -1

  # Pick this end's attach y. When stagger is active and the bus has
  # multiple arrows, distribute lanes evenly across the bar's flat
  # region (between the rounded corners) so every arrow emerges from
  # inside the bar's visible area. Otherwise fall back to the
  # configured attach mode (smart / type_zoned / center).
  defp compute_attach_y(:source, geom, side, attach_class, ctx) do
    if y_stagger_active?(geom, :source, ctx) do
      bar_distributed_y(geom.from_pos, geom.source_lane, geom.source_bus_size, ctx)
    else
      attach_y(geom.from_pos, geom.from_event, side, attach_class, ctx)
    end
  end

  defp compute_attach_y(:target, geom, side, attach_class, ctx) do
    if y_stagger_active?(geom, :target, ctx) do
      bar_distributed_y(geom.to_pos, geom.target_lane, geom.target_bus_size, ctx)
    else
      attach_y(geom.to_pos, geom.to_event, side, attach_class, ctx)
    end
  end

  defp y_stagger_active?(geom, :source, ctx) do
    not milestone?(geom.from_event) and
      geom.source_bus_size > 1 and
      task_stagger(geom.from_event, :outgoing, ctx) > 0
  end

  defp y_stagger_active?(geom, :target, ctx) do
    not milestone?(geom.to_event) and
      geom.target_bus_size > 1 and
      task_stagger(geom.to_event, :incoming, ctx) > 0
  end

  # Distribute lanes evenly across the bar's flat region (between rounded
  # corners). Lane 0 lands at the top of the flat region, lane (N-1) at
  # the bottom. Result is symmetric around bar center. With lane order
  # = sort by other-end row top, this also makes upper-row arrows
  # naturally emerge from upper part of the bar (and vice versa).
  #
  # The inset is `corner_clearance + @stroke_buffer_px` so the line's
  # stroke (up to ~2.25px for critical) stays fully inside the bar's
  # flat edge, not bleeding into the rounded corner where the bar's
  # right/left edge curves inward.
  @stroke_buffer_px 2

  defp bar_distributed_y(pos, lane, bus_size, ctx) do
    bar_top = pos.top + 4
    bar_height = max(ctx.row_px - 8, 8)
    inset = ctx.bus_stagger_corner_clearance_px + @stroke_buffer_px

    flat_top = bar_top + inset
    flat_height = max(bar_height - 2 * inset, 0)

    cond do
      bus_size <= 1 or flat_height == 0 ->
        bar_top + div(bar_height, 2)

      true ->
        # Use integer floor-div for the per-lane spacing so every gap is
        # the same number of pixels (`flat_height / (n-1)` rounded down).
        # Then center the resulting spread inside the flat region by
        # splitting the leftover gap between top and bottom margins —
        # this keeps the lanes symmetric around the bar center even when
        # `flat_height` doesn't divide evenly.
        spacing = div(flat_height, bus_size - 1)
        leftover = flat_height - spacing * (bus_size - 1)
        margin = div(leftover, 2)
        flat_top + margin + lane * spacing
    end
  end

  # -- Bar-collision avoidance --
  #
  # Builds a flat list of every bar's pixel rectangle, then shifts the
  # trunk x of forward arrows (and the final vertical of backward FS
  # arrows) to dodge intermediate-row bars that lie on the preferred x.
  #
  # The shift is bounded by each dep type's valid range so the arrow's
  # shape family doesn't break (FS trunks stay between source and
  # target; SS trunks stay west of both; FF/SF trunks stay east of both).
  # If no bar-free x exists in the valid range, we keep the preferred
  # placement — an arrow crossing a bar is better than a broken shape.

  defp compute_bar_obstacles(sorted_events, row_positions, view, day_px, row_px, min_bar_px) do
    sorted_events
    |> Enum.flat_map(fn event ->
      pos = Map.get(row_positions.positions, event.id)
      bar = bar_geometry(event, view, day_px, min_bar_px)

      # Defensive: an out-of-window bar has no left_px/width_px/milestone keys.
      # Partition already filters these out (it shares `view` with bar_geometry),
      # so this only guards against a future divergence — skip rather than crash.
      if bar[:out_of_range] do
        []
      else
        # Milestone diamonds are ~16px rotated 45° — use a symmetric 11px
        # half-width hit box around their center (which equals bar.left_px
        # since width_px == 0 for milestones).
        {x_left, x_right} =
          if bar.milestone do
            {bar.left_px - 11, bar.left_px + 11}
          else
            {bar.left_px, bar.left_px + bar.width_px}
          end

        [
          %{
            event_id: event.id,
            y_top: pos.top + 1,
            y_bottom: pos.top + row_px - 1,
            x_left: x_left,
            x_right: x_right
          }
        ]
      end
    end)
  end

  # Returns a {min_x, max_x} range where mid_x can legally land for the
  # given exit/entry combination. The forward path shape `M x1 H mid V y2
  # H x2` requires mid_x to sit on the correct side of each stem for the
  # arrow tangent to orient properly.
  defp mid_valid_range(x1, arrow_stop, :east, :west) do
    # FS — between source_exit (min stem) and target_approach (arrow
    # marker clearance). Matches the clamp range used in `choose_mid_x`
    # so collision avoidance shifts the trunk within the same shape-
    # preserving bounds rather than into arrowhead territory.
    {x1 + @min_exit_stem_px, arrow_stop - @min_approach_px}
  end

  defp mid_valid_range(x1, arrow_stop, :west, :west) do
    # SS — west of both stems.
    cap = min(x1, arrow_stop) - @elbow_px
    {cap - 10_000, cap}
  end

  defp mid_valid_range(x1, arrow_stop, :east, :east) do
    # FF — east of both stems.
    floor = max(x1, arrow_stop) + @elbow_px
    {floor, floor + 10_000}
  end

  defp mid_valid_range(x1, arrow_stop, :west, :east) do
    # SF — east of max(x1, arrow_stop), routing around the right side.
    floor = max(x1, arrow_stop) + @elbow_px
    {floor, floor + 10_000}
  end

  # Shift `preferred` to the nearest bar-free x in `[min_x, max_x]`.
  # If the preferred is already clean, or collision avoidance is off,
  # or no candidate is clean, return preferred unchanged.
  defp maybe_shift_trunk(preferred, _y1, _y2, _range, _exclude, %{avoid_collisions: false}),
    do: preferred

  defp maybe_shift_trunk(preferred, _y1, _y2, _range, _exclude, %{bars: []}), do: preferred

  defp maybe_shift_trunk(preferred, y1, y2, {min_x, max_x}, exclude_ids, ctx) do
    bars_in_span = bars_crossing_span(ctx.bars, y1, y2, exclude_ids)

    # Hard chart boundary — never push the trunk past the right edge
    # of the SVG canvas (where it would be invisible). If no clean
    # column exists within the visible area, fall back to `preferred`
    # and accept the on-screen overlap — a faint collision the user
    # can see beats a trunk drawn off-screen.
    max_x = min(max_x, Map.get(ctx, :content_width, max_x))

    if trunk_collides?(preferred, bars_in_span) do
      preferred
      |> candidate_xs(bars_in_span)
      |> Enum.filter(fn x -> x >= min_x and x <= max_x end)
      |> Enum.find(fn x -> not trunk_collides?(x, bars_in_span) end)
      |> Kernel.||(preferred)
    else
      preferred
    end
  end

  # Filter obstacles down to those whose y-range overlaps the trunk's
  # y-span — every other bar is irrelevant for this arrow.
  defp bars_crossing_span(bars, y_a, y_b, exclude_ids) do
    {y_low, y_high} = if y_a <= y_b, do: {y_a, y_b}, else: {y_b, y_a}

    Enum.filter(bars, fn b ->
      not MapSet.member?(exclude_ids, b.event_id) and
        b.y_top < y_high and b.y_bottom > y_low
    end)
  end

  defp trunk_collides?(x, bars) do
    Enum.any?(bars, fn b -> b.x_left < x and x < b.x_right end)
  end

  # Candidate xs = the left and right edges (± 3px margin) of every bar
  # currently blocking the trunk, sorted by distance from `preferred`.
  # Picking the closest clean candidate keeps the visual deviation small.
  defp candidate_xs(preferred, bars) do
    margin = 3

    bars
    |> Enum.flat_map(fn b -> [b.x_left - margin, b.x_right + margin] end)
    |> Enum.uniq()
    |> Enum.sort_by(fn x -> abs(x - preferred) end)
  end

  # Push detour_y past obstructing bars. Two obstacle flavors:
  #
  #   Line: the final vertical at x=stem_in spanning [detour_y, y2]
  #         must clear any bar whose x contains stem_in. Push past
  #         deepest (down) / highest (up) bar's edge.
  #
  #   Label: when the arrow carries a label, its rect (centered on the
  #          horizontal leg at detour_y, ~12px tall) must also clear
  #          bars whose x overlaps the rect's x-range. Push past such
  #          bars by half the rect height plus margin.
  #
  # Line margin is a quarter of a row-height so the line visibly
  # clears the row below/above the obstructing bar (not just 1px).
  defp push_detour_past_obstructions(
         preferred,
         _stem_in,
         _y2,
         _dir_sign,
         _row_px,
         _exclude_ids,
         %{avoid_collisions: false},
         _label_box
       ),
       do: preferred

  defp push_detour_past_obstructions(
         preferred,
         _stem_in,
         _y2,
         _dir_sign,
         _row_px,
         _exclude_ids,
         %{bars: []},
         _label_box
       ),
       do: preferred

  defp push_detour_past_obstructions(
         preferred,
         stem_in,
         y2,
         dir_sign,
         row_px,
         exclude_ids,
         ctx,
         label_box
       ) do
    # Per-connector bar_clearance is folded into ctx.line_margin in
    # build_path; falls back to row_px/4 when no override is set.
    clearance = Map.get(ctx, :line_margin) || div(row_px, 4)

    obstacle_pushes =
      collect_obstacle_pushes(
        preferred,
        stem_in,
        y2,
        dir_sign,
        exclude_ids,
        ctx,
        label_box,
        clearance
      )

    if obstacle_pushes == [] do
      preferred
    else
      # Cap at the TARGET ROW's near boundary minus a small clearance:
      # `target_row_top - clearance` when going down, mirror going up.
      # NOT `y2 - row_px/2` — that only equals the row top when y2 is at
      # row center, which is no longer true once Y stagger or bar-edge
      # attach push y2 away from the center (a trap where detour_y could
      # land inside the bar one row above target).
      cap = detour_cap(y2, dir_sign, clearance, ctx)

      if dir_sign > 0 do
        obstacle_pushes |> Enum.max() |> min(cap)
      else
        obstacle_pushes |> Enum.min() |> max(cap)
      end
    end
  end

  # Cap is the target ROW's near boundary: detour_y must not cross into
  # the target row from above (when going down) or from below (when
  # going up). Once at the boundary, stem_in's vertical from detour_y
  # to y2 cleanly enters the target row. `ctx.target_row_top` is set
  # per connector in `build_path`.
  defp detour_cap(y2, dir_sign, _clearance, ctx) do
    case Map.get(ctx, :target_row_top) do
      nil ->
        # Legacy fallback: assumes y2 ≈ row center.
        if dir_sign > 0, do: y2 - div(ctx.row_px, 2), else: y2 + div(ctx.row_px, 2)

      top ->
        if dir_sign > 0, do: top, else: top + ctx.row_px
    end
  end

  defp collect_obstacle_pushes(
         preferred,
         stem_in,
         y2,
         dir_sign,
         exclude,
         ctx,
         label_box,
         line_margin
       ) do
    {span_low, span_high} = if preferred <= y2, do: {preferred, y2}, else: {y2, preferred}
    label_half_h = if label_box, do: label_box.half_height, else: 0
    label_margin = label_half_h + 2

    line_pushes =
      ctx.bars
      |> line_obstacles(stem_in, span_low, span_high, exclude)
      |> Enum.map(&push_past_bar(&1, dir_sign, line_margin))

    label_pushes =
      if label_box do
        ctx.bars
        |> label_obstacles(label_box, span_low, span_high, label_half_h, exclude)
        |> Enum.map(&push_past_bar(&1, dir_sign, label_margin))
      else
        []
      end

    line_pushes ++ label_pushes
  end

  defp line_obstacles(bars, stem_in, span_low, span_high, exclude) do
    Enum.filter(bars, fn b ->
      not MapSet.member?(exclude, b.event_id) and
        b.x_left < stem_in and stem_in < b.x_right and
        b.y_top < span_high and b.y_bottom > span_low
    end)
  end

  defp label_obstacles(bars, label_box, span_low, span_high, half_h, exclude) do
    Enum.filter(bars, fn b ->
      not MapSet.member?(exclude, b.event_id) and
        b.x_left < label_box.x_max and b.x_right > label_box.x_min and
        b.y_top < span_high + half_h and b.y_bottom > span_low - half_h
    end)
  end

  defp push_past_bar(bar, 1, margin), do: bar.y_bottom + margin
  defp push_past_bar(bar, -1, margin), do: bar.y_top - margin

  # Iteratively reshape the detour until stems and detour_y are mutually
  # consistent — neither stem's vertical pierces a bar, AND the
  # horizontal leg at detour_y doesn't sit inside any bar overlapping
  # the leg's x range. Each round:
  #   1. Shift stems based on current detour_y.
  #   2. Push detour_y based on the new stems' leg extent.
  #   3. If anything moved, repeat.
  # Bounded by `max_iters` so a pathological cycle can't loop forever.
  defp converge_detour_geometry(
         stem_out,
         stem_in,
         detour_y,
         x1,
         y1,
         arrow_stop,
         y2,
         dir_sign,
         route,
         ctx,
         iters_left \\ 8
       )

  defp converge_detour_geometry(stem_out, stem_in, detour_y, _, _, _, _, _, _, _, 0),
    do: {stem_out, stem_in, detour_y}

  defp converge_detour_geometry(
         stem_out,
         stem_in,
         detour_y,
         x1,
         y1,
         arrow_stop,
         y2,
         dir_sign,
         route,
         ctx,
         iters_left
       ) do
    new_stem_out = maybe_shift_stem_out(stem_out, x1, y1, detour_y, route, ctx)
    new_stem_in = maybe_shift_stem_in(stem_in, arrow_stop, detour_y, y2, route, ctx)

    new_detour_y =
      push_detour_for_horizontal_leg(
        detour_y,
        new_stem_out,
        new_stem_in,
        y2,
        dir_sign,
        ctx.row_px,
        route.exclude_ids,
        ctx
      )

    if new_stem_out == stem_out and new_stem_in == stem_in and new_detour_y == detour_y do
      {stem_out, stem_in, detour_y}
    else
      converge_detour_geometry(
        new_stem_out,
        new_stem_in,
        new_detour_y,
        x1,
        y1,
        arrow_stop,
        y2,
        dir_sign,
        route,
        ctx,
        iters_left - 1
      )
    end
  end

  # After stems are shifted, the horizontal leg from stem_out to stem_in
  # at detour_y may now overlap unrelated bars whose y range contains
  # detour_y AND whose x range overlaps the leg. Push detour_y past
  # those bars (toward target). Capped at y2 ± row_px/2 like the main
  # push so the detour doesn't enter the target row.
  defp push_detour_for_horizontal_leg(
         preferred,
         stem_out,
         stem_in,
         y2,
         dir_sign,
         row_px,
         exclude_ids,
         ctx
       ) do
    if not Map.get(ctx, :avoid_collisions, true) do
      preferred
    else
      leg_left = min(stem_out, stem_in)
      leg_right = max(stem_out, stem_in)
      margin = Map.get(ctx, :line_margin) || div(row_px, 4)

      # Cap at target ROW boundary, not `y2 ± row_px/2` (see comment in
      # `detour_cap/4` — that legacy expression assumed y2 was at row
      # center, which Y stagger breaks).
      cap = detour_cap(y2, dir_sign, margin, ctx)

      iterate_horizontal_push(
        preferred,
        leg_left,
        leg_right,
        dir_sign,
        margin,
        exclude_ids,
        ctx.bars,
        cap,
        # iteration limit so a pathological case can't loop forever
        10
      )
    end
  end

  # Repeatedly push detour_y past any bar that intersects the leg, until
  # no more bars intersect or we hit the cap or iteration limit. One pass
  # only handles the immediate obstruction; pushing past it can land us
  # inside the NEXT bar in the next row, so we have to re-check.
  defp iterate_horizontal_push(preferred, _ll, _lr, _dir, _m, _ex, _bars, _cap, 0),
    do: preferred

  defp iterate_horizontal_push(
         preferred,
         leg_left,
         leg_right,
         dir_sign,
         margin,
         exclude_ids,
         bars,
         cap,
         iters_left
       ) do
    pierced =
      Enum.filter(bars, fn b ->
        not MapSet.member?(exclude_ids, b.event_id) and
          b.x_left < leg_right and b.x_right > leg_left and
          b.y_top < preferred and b.y_bottom > preferred
      end)

    case pierced do
      [] ->
        preferred

      _ ->
        new =
          pierced
          |> Enum.map(&push_past_bar(&1, dir_sign, margin))
          |> then(fn ps -> if dir_sign > 0, do: Enum.max(ps), else: Enum.min(ps) end)

        capped =
          if dir_sign > 0,
            do: min(new, cap),
            else: max(new, cap)

        if capped == preferred do
          preferred
        else
          iterate_horizontal_push(
            capped,
            leg_left,
            leg_right,
            dir_sign,
            margin,
            exclude_ids,
            bars,
            cap,
            iters_left - 1
          )
        end
    end
  end

  # When detour_y is pushed deep past obstructions, stem_out's vertical
  # span (y1 → detour_y) can extend through several intermediate rows.
  # If a bar at stem_out's preferred x sits in that span, the vertical
  # line pierces it. Shift stem_out to the nearest bar-edge x that's
  # clean — preferring east (positive offset) since stem_out must satisfy
  # `stem_out > x1` for the FS detour shape to remain coherent.
  defp maybe_shift_stem_out(preferred, x1, y1, detour_y, route, ctx) do
    if not Map.get(ctx, :avoid_collisions, true) do
      preferred
    else
      shift_stem(preferred, y1, detour_y, route.exclude_ids, ctx, fn x -> x > x1 end)
    end
  end

  # Same idea for stem_in's vertical (detour_y → y2). The constraint here
  # is `stem_in < arrow_stop` (must be west of the arrow tip).
  defp maybe_shift_stem_in(preferred, arrow_stop, detour_y, y2, route, ctx) do
    if not Map.get(ctx, :avoid_collisions, true) do
      preferred
    else
      shift_stem(preferred, detour_y, y2, route.exclude_ids, ctx, fn x -> x < arrow_stop end)
    end
  end

  defp shift_stem(preferred, y_a, y_b, exclude_ids, ctx, valid_fn) do
    bars_in_span = bars_crossing_span(ctx.bars, y_a, y_b, exclude_ids)

    if trunk_collides?(preferred, bars_in_span) do
      preferred
      |> candidate_xs(bars_in_span)
      |> Enum.filter(valid_fn)
      |> Enum.find(fn x -> not trunk_collides?(x, bars_in_span) end)
      |> Kernel.||(preferred)
    else
      preferred
    end
  end

  # Styling is resolved per-path in `resolve_style/3`. See `build_path/3`
  # for how the category (normal / critical / invalid) is picked and how
  # per-connector overrides fall through onto the component defaults.
  # Everything else — color, stroke_width, dasharray, opacity, marker,
  # label fill — is driven by the path struct's fields. No other helpers.

  # -- Milestone detection (zero-duration event) --

  # A task is a milestone iff it has zero (fractional-day) duration — the SAME
  # test `bar_geometry/3` uses (`fe - fs <= 0`). Measuring in fractional days
  # (not date-truncated days) is essential since `:hour` zoom / sub-day
  # temporals exist: a 2-hour task starts and ends on the same DATE, so a
  # `Date.diff` test wrongly classified it as a milestone — the connector router
  # then applied milestone endpoint offsets + the 10px diamond gap while the bar
  # rendered as a thin bar, so arrows routed to/from a phantom diamond and
  # appeared disconnected. For pure-`Date` events this is identical to the old
  # `Date.diff` test (frac duration == date diff), so day/week/month is unchanged.
  defp milestone?(%LiveGantt.Task{} = event) do
    ref = to_date(event.start)
    duration = frac_days(LiveGantt.Task.effective_end(event), ref) - frac_days(event.start, ref)
    duration <= 0
  end

  # -- Grouping --

  defp build_groups(sorted_events) do
    sorted_events
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {event, idx}, acc ->
      group = get_group(event)
      Map.update(acc, group, idx, fn first_idx -> min(first_idx, idx) end)
    end)
  end

  defp show_group_header?(groups, event, idx) do
    group = get_group(event)
    group != nil and Map.get(groups, group) == idx
  end

  defp get_group(%LiveGantt.Task{category: cat}) when not is_nil(cat), do: to_string(cat)

  defp get_group(%LiveGantt.Task{extra: %{group: group}}) when not is_nil(group),
    do: to_string(group)

  defp get_group(_), do: nil

  # -- Range filtering --

  # Partition the event list by whether each event's `[start, end)` has any
  # overlap with the visible `date_range`. Returns a 3-tuple:
  #
  #   {in_range, earlier_count, later_count}
  #
  # Out-of-range events are dropped from all downstream rendering (no row,
  # no bar, no connector) but the counts are surfaced as edge indicators
  # so the user sees there's more data outside the window.
  # Validate event ids are unique across the entire input list. Duplicate
  # ids would produce duplicate DOM element ids (bar wrappers, popovers,
  # connector endpoints) and silently break: clicks would target whichever
  # `getElementById` returned first, arrows would attach to the wrong bar,
  # popover state would smear across the duplicates. Raise loudly at
  # render-time instead of debugging visual glitches later.
  defp validate_event_ids!(events) do
    {_seen, dups} =
      Enum.reduce(events, {MapSet.new(), MapSet.new()}, fn ev, {seen, dups} ->
        cond do
          is_nil(ev.id) -> {seen, dups}
          MapSet.member?(seen, ev.id) -> {seen, MapSet.put(dups, ev.id)}
          true -> {MapSet.put(seen, ev.id), dups}
        end
      end)

    case MapSet.to_list(dups) do
      [] ->
        :ok

      ids ->
        raise ArgumentError, """
        LiveGantt.gantt/1: duplicate event ids found in `events`: #{inspect(ids)}.

        Every event must have a unique `id`. Duplicate ids produce duplicate
        DOM element ids (bar wrappers, popovers, connector endpoints) which
        break click-targeting, arrow attachment and popover state.
        """
    end
  end

  defp partition_events_by_range(events, {origin, span_days} = _view) do
    Enum.reduce(events, {[], 0, 0}, fn event, {in_range, earlier, later} ->
      cond do
        # Drop events missing a start date entirely — without it there
        # is nothing to position the bar against. Silent (no Logger
        # call) so a malformed task can't spam the host app's logs.
        is_nil(event.start) or is_nil(LiveGantt.Task.effective_end(event)) ->
          {in_range, earlier, later}

        true ->
          # Use the SAME fractional-day overlap (and the SAME origin/span) that
          # `bar_geometry/4` uses, so partition and bar rendering agree on what's
          # visible. They MUST: an event admitted here but clipped by
          # `bar_geometry` returns `%{out_of_range: true}` and the template
          # crashes on `bar.milestone`.
          fs = frac_days(event.start, origin)
          fe = frac_days(LiveGantt.Task.effective_end(event), origin)
          is_milestone = fe - fs <= 0

          cond do
            not out_of_range_frac?(fs, fe, is_milestone, span_days) ->
              {[event | in_range], earlier, later}

            fs < 0 ->
              {in_range, earlier + 1, later}

            true ->
              {in_range, earlier, later + 1}
          end
      end
    end)
    |> then(fn {in_range, e, l} -> {Enum.reverse(in_range), e, l} end)
  end

  # -- Layout ordering --

  # Sort events to minimize arrow crossings. Within each group, events are
  # placed in a modified topological order: start-date ordered, but whenever
  # an event is placed, any of its direct dependents whose other prerequisites
  # are already placed get placed immediately after it (adjacent). Users can
  # override the computed position by setting `extra.order` (integer) on
  # specific events.
  defp sort_events_for_layout(events, connectors) do
    auto_positions = compute_auto_positions(events, connectors)

    Enum.sort_by(events, fn e ->
      group = get_group(e)
      position = explicit_order(e) || Map.get(auto_positions, e.id, 0)
      {group || "", position, to_string(e.id)}
    end)
  end

  defp explicit_order(%LiveGantt.Task{extra: %{order: order}}) when is_integer(order), do: order
  defp explicit_order(_), do: nil

  # Compute an integer placement index for each event within its group.
  # Events with no in-group dependencies are placed by start_date. Direct
  # dependents get placed right after their source when possible.
  defp compute_auto_positions(events, connectors) do
    events
    |> Enum.group_by(&get_group/1)
    |> Enum.flat_map(fn {_group, group_events} ->
      group_events
      |> auto_place_group(connectors)
      |> Enum.with_index()
      |> Enum.map(fn {event, idx} -> {event.id, idx} end)
    end)
    |> Map.new()
  end

  defp auto_place_group(group_events, all_connectors) do
    group_ids = MapSet.new(group_events, & &1.id)

    in_group_edges =
      Enum.filter(all_connectors, fn c ->
        MapSet.member?(group_ids, c.from) and MapSet.member?(group_ids, c.to)
      end)

    # `deps_by_source` keeps `{to_id, critical?}` tuples (not just ids) so
    # `place_dependents/5` can sort dependents critical-first. This lets the
    # critical-path chain land on adjacent rows even when a parallel branch
    # has an earlier start date.
    deps_by_source =
      Enum.group_by(in_group_edges, & &1.from, &{&1.to, Map.get(&1, :critical, false)})

    preds_by_target = Enum.group_by(in_group_edges, & &1.to, & &1.from)
    events_by_id = Map.new(group_events, &{&1.id, &1})

    # IMPORTANT: pass `Date` as the third arg so `Date.compare/2` is used.
    # Default term ordering on `Date` structs compares by struct keys
    # alphabetically (`:day` first), so without this `~D[2026-07-05]` would
    # sort before `~D[2026-05-14]` because day-of-month 5 < 14.
    sorted_by_date = Enum.sort_by(group_events, &to_date(&1.start), Date)

    {placed, _placed_set} =
      Enum.reduce(sorted_by_date, {[], MapSet.new()}, fn event, {placed, placed_set} ->
        if MapSet.member?(placed_set, event.id) do
          {placed, placed_set}
        else
          # Place this event
          placed = [event | placed]
          placed_set = MapSet.put(placed_set, event.id)

          # Immediately after, try to place each direct dependent whose other
          # predecessors are also already placed.
          place_dependents(
            event,
            events_by_id,
            deps_by_source,
            preds_by_target,
            {placed, placed_set}
          )
        end
      end)

    Enum.reverse(placed)
  end

  # Recursively place direct dependents (and their dependents) adjacent to
  # source when their prerequisites are met. Sort key is
  # `{not critical?, start_date}` — so when a source has both a critical-path
  # dependent and a parallel-branch dependent, the critical one is placed
  # first regardless of which has the earlier start date. This keeps the
  # critical chain on adjacent rows for visual continuity.
  defp place_dependents(
         event,
         events_by_id,
         deps_by_source,
         preds_by_target,
         {placed, placed_set}
       ) do
    dependent_specs = Map.get(deps_by_source, event.id, [])

    dependent_events =
      dependent_specs
      |> Enum.map(fn {dep_id, critical?} ->
        case Map.get(events_by_id, dep_id) do
          nil -> nil
          event -> {event, critical?}
        end
      end)
      |> Enum.filter(& &1)
      # Sort key includes a Date in a tuple, so we can't pass `Date` as the
      # third arg. Convert to gregorian-days int so the tuple compare works
      # correctly (otherwise default Date term ordering compares :day first).
      |> Enum.sort_by(fn {event, critical?} ->
        {not critical?, Date.to_gregorian_days(to_date(event.start))}
      end)

    Enum.reduce(dependent_events, {placed, placed_set}, fn {dep, _critical?}, {p, s} ->
      cond do
        MapSet.member?(s, dep.id) ->
          {p, s}

        not all_predecessors_placed?(dep, preds_by_target, s) ->
          {p, s}

        true ->
          # Place dependent, then recurse on its dependents
          new_placed = [dep | p]
          new_set = MapSet.put(s, dep.id)

          place_dependents(
            dep,
            events_by_id,
            deps_by_source,
            preds_by_target,
            {new_placed, new_set}
          )
      end
    end)
  end

  defp all_predecessors_placed?(event, preds_by_target, placed_set) do
    preds = Map.get(preds_by_target, event.id, [])
    Enum.all?(preds, &MapSet.member?(placed_set, &1))
  end

  # -- Progress --

  # Struct field wins; `extra.progress_pct` is the fallback for consumers that
  # carry their data in `extra`. The struct default is `nil`, so an unset field
  # transparently defers to `extra`.
  defp progress_pct(%LiveGantt.Task{progress_pct: pct}) when is_number(pct), do: pct
  defp progress_pct(%LiveGantt.Task{extra: %{progress_pct: pct}}) when is_number(pct), do: pct
  defp progress_pct(_), do: 0

  defp assignee(%LiveGantt.Task{assignee: a}) when is_binary(a), do: a
  defp assignee(%LiveGantt.Task{extra: %{assignee: a}}) when is_binary(a), do: a
  defp assignee(_), do: nil

  # -- Sub-project tree helpers --
  #
  # An event becomes a sub-project (a roll-up container) by carrying
  # `extra.parent_id => "<some-other-event-id>"`. Multiple events can
  # share the same parent_id (siblings in a sub-project), and a
  # sub-project event can itself have a parent_id (recursion is
  # unbounded). Events whose parent_id points to an event that isn't
  # in the list are treated as top-level.

  defp parent_id_of(%LiveGantt.Task{extra: %{parent_id: pid}})
       when is_binary(pid) or is_atom(pid),
       do: to_string(pid)

  defp parent_id_of(_), do: nil

  # Walk the event list once, returning a parent_id → [child_ids] map
  # plus a reverse child_id → parent_id map. Both keep entries only
  # for parents that actually exist in the list.
  defp build_event_tree(events) do
    by_id = Map.new(events, &{&1.id, &1})

    {children, parents} =
      Enum.reduce(events, {%{}, %{}}, fn ev, {ch, pa} ->
        case parent_id_of(ev) do
          nil ->
            {ch, pa}

          pid ->
            cond do
              not Map.has_key?(by_id, pid) -> {ch, pa}
              # Reject self-reference and any chain that would close a cycle
              # (parent's existing ancestor chain already contains the child).
              pid == ev.id -> {ch, pa}
              cycle?(pid, ev.id, pa) -> {ch, pa}
              true -> {Map.update(ch, pid, [ev.id], &[ev.id | &1]), Map.put(pa, ev.id, pid)}
            end
        end
      end)

    # Reverse so children stay in original (sorted) order
    children = Map.new(children, fn {k, v} -> {k, Enum.reverse(v)} end)

    %{by_id: by_id, children: children, parents: parents}
  end

  # True if walking up `start`'s parent chain reaches `target`. Used at
  # tree-build time to refuse any new parent_id link that would close a
  # cycle — without this guard, `ancestor_ids/2`, `effective_id/3`, and
  # `descendants_of/2` would all recurse forever and hang the render.
  defp cycle?(start, target, parents) do
    cycle_walk?(start, target, parents, %{})
  end

  defp cycle_walk?(id, target, _parents, _seen) when id == target, do: true

  defp cycle_walk?(id, target, parents, seen) do
    cond do
      Map.has_key?(seen, id) ->
        false

      true ->
        case Map.get(parents, id) do
          nil -> false
          pid -> cycle_walk?(pid, target, parents, Map.put(seen, id, true))
        end
    end
  end

  # True if the event has at least one child in the same event list.
  defp sub_project?(event, tree), do: Map.has_key?(tree.children, event.id)

  # Walk up the parent chain. Result includes the event's own id at
  # the head and the eventual top-level ancestor at the tail.
  defp ancestor_ids(id, tree) do
    case Map.get(tree.parents, id) do
      nil -> [id]
      pid -> [id | ancestor_ids(pid, tree)]
    end
  end

  # Depth from root — 0 for top-level, 1 for first nested, etc.
  defp depth_of(id, tree), do: length(ancestor_ids(id, tree)) - 1

  # The id that should actually be rendered for `id` given which
  # sub-projects are expanded. Walks UP the parent chain — for each
  # ancestor that is NOT expanded, the visible id is that ancestor
  # (the roll-up bar). Returns `id` itself if all ancestors are
  # expanded or it has no parents.
  defp effective_id(id, tree, expanded) do
    case Map.get(tree.parents, id) do
      nil ->
        id

      pid ->
        case effective_id(pid, tree, expanded) do
          ^pid -> if MapSet.member?(expanded, pid), do: id, else: pid
          # An ancestor higher up is collapsed — that ancestor wins.
          higher -> higher
        end
    end
  end

  # True if the event sits INSIDE an expanded sub-project — i.e. one of
  # its ancestors is expanded. The sub-project parent itself returns
  # false; we want the tint to apply only to the children that the
  # parent visually contains.
  defp in_open_subproject?(event, tree, expanded) do
    event.id
    |> ancestor_ids(tree)
    |> tl()
    |> Enum.any?(&MapSet.member?(expanded, &1))
  end

  # Pick a frame color by nesting depth. `parent_depth` is the depth
  # of the sub-project that the row/frame belongs to (top-level
  # sub-project = 0, sub-project inside one = 1, etc.). Cycles
  # through the list once depth exceeds list length so deeper
  # nesting still gets a stable color. Passing a single string skips
  # the per-depth logic and always returns that same color.
  defp frame_color_for(colors, parent_depth) when is_list(colors) and colors != [] do
    Enum.at(colors, rem(parent_depth, length(colors)))
  end

  defp frame_color_for(color, _parent_depth) when is_binary(color), do: color
  defp frame_color_for(_, _), do: "#FEF3C7"

  # Events that should be visible given the current expanded set: any
  # event whose parents are ALL expanded (or that has no parents).
  defp visible_events(events, tree, expanded) do
    Enum.filter(events, fn ev ->
      ev.id
      |> ancestor_ids(tree)
      |> tl()
      |> Enum.all?(&MapSet.member?(expanded, &1))
    end)
  end

  # Recursively collect every descendant id of `id` in the tree.
  defp descendants_of(id, tree) do
    case Map.get(tree.children, id) do
      nil ->
        []

      child_ids ->
        child_ids ++ Enum.flat_map(child_ids, &descendants_of(&1, tree))
    end
  end

  # Convert the consumer-provided `expanded` attr (nil, list, or
  # MapSet) into a MapSet for fast membership checks. nil → empty
  # (all sub-projects collapsed by default).
  # `expanded` accepts:
  #   * `nil` or `[]` → nothing expanded
  #   * a `MapSet` or list of event ids → exactly those expanded
  #   * `:all` → every event in the input is expanded (callers want
  #     "show everything" without listing ids; expand to a concrete
  #     set so all downstream `MapSet.member?` checks stay branchless)
  defp normalize_expanded(nil, _events), do: MapSet.new()
  defp normalize_expanded(:all, events), do: MapSet.new(events, & &1.id)
  defp normalize_expanded(%MapSet{} = set, _events), do: set
  defp normalize_expanded(list, _events) when is_list(list), do: MapSet.new(list)
  defp normalize_expanded(_, _events), do: MapSet.new()

  # For every sub-project event that doesn't carry its own start/end,
  # synthesize them from the min/max of its leaf descendants' dates.
  # Events with explicit dates are left untouched so consumers can
  # override the auto-rollup when they want a specific range.
  defp rollup_subproject_dates(events, tree) do
    by_id = tree.by_id

    Enum.map(events, fn ev ->
      cond do
        not sub_project?(ev, tree) ->
          ev

        # Raw `start` AND `end` set — consumer wants this parent to
        # span their explicit dates, not the children's range.
        ev.start && ev.end ->
          ev

        true ->
          ev.id
          |> descendants_of(tree)
          |> Enum.map(&Map.get(by_id, &1))
          |> Enum.reject(&is_nil/1)
          |> rolled_up_range()
          |> case do
            nil -> ev
            {min_start, max_end} -> %LiveGantt.Task{ev | start: min_start, end: max_end}
          end
      end
    end)
  end

  defp rolled_up_range([]), do: nil

  defp rolled_up_range(events) do
    # Roll up in the children's NATIVE temporal type — do NOT truncate to dates.
    # Truncating collapsed a parent of sub-day children (e.g. 10:00–14:00) to
    # start == end on one date, which `bar_geometry/4` then drew as a midnight
    # milestone diamond while the children sat at their real hours. Comparing via
    # `to_naive_dt/1` keeps mixed Date/NaiveDateTime/DateTime children orderable
    # while returning the original (untruncated) endpoints.
    starts = events |> Enum.map(& &1.start) |> Enum.reject(&is_nil/1)

    ends =
      events
      |> Enum.map(&LiveGantt.Task.effective_end/1)
      |> Enum.reject(&is_nil/1)

    case {starts, ends} do
      {[], _} ->
        nil

      {_, []} ->
        nil

      {ss, es} ->
        {Enum.min_by(ss, &to_naive_dt/1, NaiveDateTime),
         Enum.max_by(es, &to_naive_dt/1, NaiveDateTime)}
    end
  end

  # Re-order an already-sorted event list so children appear directly
  # after their parent (recursively). Top-level events keep their
  # sorter-derived order; for each one, its descendants get spliced
  # in immediately, in their original sorter order. This makes the
  # expanded sub-project read as a contiguous group instead of having
  # the children scatter to wherever date-sort would put them.
  defp cluster_subprojects(events, tree) do
    by_id = Map.new(events, &{&1.id, &1})

    # Top-level (within the visible set) = no `tree.parents` entry,
    # i.e. the tree-builder didn't accept a parent link for this
    # event. Consulting the tree (rather than re-reading
    # `parent_id_of/1` directly) means cycle-closing or unresolved
    # parent_ids that the builder rejected don't accidentally remove
    # the event from the top-level set here.
    top_level =
      Enum.filter(events, fn ev ->
        not Map.has_key?(tree.parents, ev.id)
      end)

    # Indices of children inside `events`, so we can recover the
    # sorter's relative order between siblings.
    order_idx = events |> Enum.with_index() |> Map.new(fn {ev, i} -> {ev.id, i} end)

    Enum.flat_map(top_level, &expand_with_children(&1, by_id, tree, order_idx))
  end

  # For every currently-expanded sub-project, compute a rectangle in
  # timeline coordinates that brackets all of its visible descendants:
  # x-range from the sub-project's rolled-up date range, y-range from
  # the topmost-to-bottommost descendant row. Used by the renderer to
  # draw a translucent frame behind the children.
  defp compute_subproject_frames(
         sorted_events,
         tree,
         expanded,
         row_positions,
         row_px,
         view,
         day_px,
         min_bar_px
       ) do
    by_id = Map.new(sorted_events, &{&1.id, &1})

    sorted_events
    |> Enum.filter(fn ev ->
      sub_project?(ev, tree) and MapSet.member?(expanded, ev.id)
    end)
    |> Enum.flat_map(fn parent ->
      descendants =
        parent.id
        |> descendants_of(tree)
        |> Enum.map(&Map.get(by_id, &1))
        |> Enum.reject(&is_nil/1)

      # Only descendants — the frame brackets the children, NOT the
      # sub-project's own roll-up row. (The roll-up bar itself stays
      # visually distinct via `bar_subproject_class`.)
      tops =
        descendants
        |> Enum.map(fn ev -> get_in(row_positions.positions, [ev.id, :top]) end)
        |> Enum.reject(&is_nil/1)

      case tops do
        [] ->
          []

        _ ->
          bar = bar_geometry(parent, view, day_px, min_bar_px)

          if Map.get(bar, :out_of_range) do
            []
          else
            # Pull the top up by the bar's 4px bottom inset so the
            # frame visually touches the sub-project's bar instead of
            # leaving a thin row-padding gap between them.
            [
              %{
                left_px: bar.left_px,
                right_px: bar.left_px + max(bar.width_px, 4),
                top_y: Enum.min(tops) - 4,
                bottom_y: Enum.max(tops) + row_px,
                parent_depth: depth_of(parent.id, tree)
              }
            ]
          end
      end
    end)
  end

  defp expand_with_children(event, by_id, tree, order_idx) do
    children =
      tree.children
      |> Map.get(event.id, [])
      |> Enum.filter(&Map.has_key?(by_id, &1))
      |> Enum.sort_by(&Map.get(order_idx, &1, 0))
      |> Enum.map(&Map.get(by_id, &1))
      |> Enum.flat_map(&expand_with_children(&1, by_id, tree, order_idx))

    [event | children]
  end

  # Walk each connector's endpoints up the parent chain to the nearest
  # visible ancestor. Connectors that collapse to the same effective
  # endpoint (both inside the same collapsed sub-project) get dropped
  # entirely — there's nothing to draw.
  defp retarget_connectors(connectors, tree, expanded) do
    connectors
    |> Enum.map(fn c ->
      from = effective_id(c.from, tree, expanded)
      to = effective_id(c.to, tree, expanded)
      %{c | from: from, to: to}
    end)
    |> Enum.reject(fn c -> c.from == c.to end)
  end

  # Subtitle for the popover — assignee and/or progress when relevant.
  # Returns nil (caller skips the row) when neither applies.
  #
  #   "Alice • 80%"   — both
  #   "Alice"         — assignee only
  #   "80%"           — progress only
  defp bar_subtitle(event) do
    parts =
      []
      |> maybe_append(assignee(event))
      |> maybe_append(progress_label(event))
      |> Enum.reverse()

    case parts do
      [] -> nil
      _ -> Enum.join(parts, " \u2022 ")
    end
  end

  defp maybe_append(list, nil), do: list
  defp maybe_append(list, ""), do: list
  defp maybe_append(list, val), do: [val | list]

  defp progress_label(event) do
    case progress_pct(event) do
      pct when is_number(pct) and pct > 0 -> "#{round(pct)}%"
      _ -> nil
    end
  end

  # -- Badges --

  # `event.extra.badges` is a list of badge maps. Anything else
  # (missing key, non-list, non-map entries) is silently dropped so a
  # typo can't crash the render.
  defp bar_badges(%LiveGantt.Task{extra: %{badges: badges}}) when is_list(badges),
    do: Enum.filter(badges, &is_map/1)

  defp bar_badges(_), do: []

  # Walk badges in declaration order, count how many we've already
  # seen at each corner, and tag each badge with its per-corner index.
  # Index 0 sits at the corner; index 1 is one badge-width away; etc.
  # Defaults to `:top_right` so plain `%{content: "..."}` maps stack
  # at the standard notification corner instead of all piling onto
  # the same spot.
  defp bar_badges_with_offsets(event) do
    {tagged, _counts} =
      event
      |> bar_badges()
      |> Enum.reduce({[], %{}}, fn badge, {acc, counts} ->
        corner = badge[:corner] || :top_right
        index = Map.get(counts, corner, 0)
        {[{badge, index} | acc], Map.put(counts, corner, index + 1)}
      end)

    Enum.reverse(tagged)
  end

  # Action badges: `:badge` (single map) or `:badges` (list). Both are
  # accepted so callers don't have to wrap a single badge in a list.
  defp action_badges(%{badges: badges}) when is_list(badges),
    do: Enum.filter(badges, &is_map/1)

  defp action_badges(%{badge: badge}) when is_map(badge), do: [badge]
  defp action_badges(_), do: []

  # Bar badge position style — pixel coords. The badge is positioned
  # inside the same row container as the bar, so coords use the bar's
  # left/right (x) and the row's top/bottom (y, which is row_top..
  # row_top+row_px). The bar itself has a 4px inset (top-1/bottom-1)
  # from the row, so badges anchor to the bar's visual corner not the
  # row's edge.
  defp badge_position_style(corner, bar, row_px, corner_index, content_width) do
    {x_anchor, y_anchor} = badge_anchor(corner, bar, row_px, corner_index, content_width)
    "#{x_anchor}; #{y_anchor}"
  end

  # Horizontal overhang only — badges stick PAST the bar's left/right
  # edge into the row's empty side-space, but stay fully WITHIN the
  # row's vertical bounds (top: 0 → top: row_px - 16). Each successive
  # badge in the same corner shifts INWARD by `@badge_stack_step_px`
  # so multiple badges in one corner sit side by side instead of on
  # top of each other.
  @badge_overhang_px 10
  @badge_size_px 16
  @badge_stack_step_px 18

  # Badges anchor to a bar corner (a % position) plus a fixed px overhang /
  # stack offset → `calc(P% + Npx)`, so they track the bar at any fill width
  # while keeping their constant pixel overhang.
  defp badge_anchor(:top_left, bar, _, idx, cw),
    do:
      {badge_left(bar.left_px, -@badge_overhang_px + idx * @badge_stack_step_px, cw), "top: 0px"}

  defp badge_anchor(:bottom_left, bar, row_px, idx, cw),
    do:
      {badge_left(bar.left_px, -@badge_overhang_px + idx * @badge_stack_step_px, cw),
       "top: #{row_px - @badge_size_px}px"}

  defp badge_anchor(:bottom_right, bar, row_px, idx, cw),
    do:
      {badge_left(
         bar_right_px(bar),
         -@badge_size_px + @badge_overhang_px - idx * @badge_stack_step_px,
         cw
       ), "top: #{row_px - @badge_size_px}px"}

  # Default = top_right.
  defp badge_anchor(_, bar, _, idx, cw),
    do:
      {badge_left(
         bar_right_px(bar),
         -@badge_size_px + @badge_overhang_px - idx * @badge_stack_step_px,
         cw
       ), "top: 0px"}

  defp badge_left(anchor_px, offset_px, content_width),
    do: "left: calc(#{pct(anchor_px, content_width)}% + #{offset_px}px)"

  # Milestones have width 0 — render right-of-center.
  defp bar_right_px(%{left_px: l, width_px: w}), do: l + w
  defp bar_right_px(%{left_px: l}), do: l

  # Action button badge: corner classes (button is `relative` so these
  # anchor to the button's box).
  defp action_badge_corner_class(:top_left), do: "absolute -top-1.5 -left-1.5"
  defp action_badge_corner_class(:bottom_left), do: "absolute -bottom-1.5 -left-1.5"
  defp action_badge_corner_class(:bottom_right), do: "absolute -bottom-1.5 -right-1.5"
  defp action_badge_corner_class(_), do: "absolute -top-1.5 -right-1.5"

  # Same shape as the component's @badge_class default — used as a
  # safe fallback when the badge is rendered outside of a place that
  # threads `class` through (none today, but future-proofs).
  defp badge_default_class do
    "inline-flex items-center justify-center px-1.5 min-w-[1.25rem] h-5 text-[0.65rem] font-bold rounded-full ring-2 ring-base-100 leading-none pointer-events-none"
  end

  # -- Bar popover / actions --

  # Per-event action buttons shown in the bar popover. Source:
  # `event.extra.actions` — a list of maps. Anything other than a list
  # is silently ignored (so consumers can't accidentally crash the
  # render with a typo). Each action map shape:
  #
  #   %{
  #     icon:       "hero-chat-bubble-left",  # required, CSS class on <span>
  #     tooltip:    "Open comments",          # optional, becomes `title` attr
  #     phx_click:  "open_comments",          # optional, becomes phx-click
  #     phx_value:  %{event_id: "..."},       # optional, expanded to phx-value-*
  #     phx_target: "#sidebar",               # optional, phx-target
  #     href:       "/events/123",            # optional, renders as <a>
  #     class:      "text-primary"            # optional, extra classes
  #   }
  defp bar_actions(%LiveGantt.Task{extra: %{actions: actions}}) when is_list(actions),
    do: Enum.filter(actions, &is_map/1)

  defp bar_actions(_), do: []

  # Action list for the popover, with an expand/collapse button
  # prepended when the event is a sub-project that has an
  # `on_toggle_expand` handler wired. The pseudo-action reuses the
  # same `bar_action_button` rendering, so it picks up the existing
  # `phx-value-event-id` plumbing and tooltip styling for free.
  defp popover_actions(event, tree, expanded, on_toggle) do
    base = bar_actions(event)

    if sub_project?(event, tree) and on_toggle do
      expanded? = MapSet.member?(expanded, event.id)

      toggle_action = %{
        id: "_subproject_toggle",
        icon: if(expanded?, do: "hero-minus-mini", else: "hero-plus-mini"),
        tooltip: if(expanded?, do: "Collapse sub-project", else: "Expand sub-project"),
        phx_click: on_toggle
      }

      [toggle_action | base]
    else
      base
    end
  end

  # DOM ids for hook targeting. `id_prefix` falls back to `"wf"` when
  # the component doesn't get an explicit `id`; multiple un-id'd
  # waterfalls on one page would collide and is unsupported anyway.
  defp bar_dom_id(id_prefix, event_id),
    do: "#{id_prefix || "lg"}-bar-#{event_id}"

  defp popover_dom_id(id_prefix, event_id),
    do: "#{id_prefix || "lg"}-bar-popover-#{event_id}"

  defp label_dom_id(id_prefix, event_id),
    do: "#{id_prefix || "lg"}-label-#{event_id}"

  defp label_popover_dom_id(id_prefix, event_id),
    do: "#{id_prefix || "lg"}-label-popover-#{event_id}"

  # Anchor the label popover to the row's exact y. Uses the
  # row_positions map computed once per render, so any group-header
  # offsets are accounted for automatically. Pad 4px so the popover's
  # top edge sits where the label content begins (matches the bar's
  # top-1 visual inset).
  defp label_popover_style(row_positions, event_id, row_px) do
    case row_positions.positions do
      %{^event_id => %{top: top}} ->
        "top: #{top + popover_top_inset()}px; min-height: #{row_px - 2 * popover_top_inset()}px"

      _ ->
        "top: 0px; min-height: #{row_px - 2 * popover_top_inset()}px"
    end
  end

  # Popover anchors to the bar's exact rectangle: same `left`, same
  # `top` (row_top + 4 to match the bar's `top-1` inset), and at least
  # as wide as the bar so it visually grows downward (and rightward
  # when the title needs more room) rather than floating separately.
  defp popover_style(bar, row_px, content_width) do
    "left: #{pct(bar.left_px, content_width)}%; " <>
      "top: #{popover_top_inset()}px; " <>
      "min-width: #{pct(bar.width_px, content_width)}%; " <>
      "min-height: #{row_px - 2 * popover_top_inset()}px"
  end

  # 4px = Tailwind `top-1` on the bar. Keep the popover's top edge in
  # the same spot so it looks like the bar expanded.
  defp popover_top_inset, do: 4

  # Renders a single action — <a href> if `:href` is set, otherwise a
  # <button> wired with phx-click / phx-value-*. Stops click propagation
  # so clicking an action doesn't also fire the bar's on_event_click.
  attr :action, :map, required: true
  attr :event_id, :string, required: true
  attr :class, :string, default: nil
  attr :disabled_class, :string, default: nil

  attr :badge_class, :string, default: nil
  attr :badge_default_color, :string, default: "bg-error"

  defp bar_action_button(assigns) do
    assigns = assign(assigns, :disabled?, !!assigns.action[:disabled])

    ~H"""
    <%= cond do %>
      <% @disabled? -> %>
        <%!-- Disabled: render as an unclickable <span>. Drops phx-click
           + href entirely so neither the browser nor LiveView fire
           anything. aria-disabled exposes state to assistive tech. --%>
        <span
          class={[
            "lg-bar-action",
            @class,
            @disabled_class,
            @action[:class]
          ]}
          title={@action[:tooltip]}
          data-action-id={@action[:id]}
          aria-disabled="true"
          role="button"
        >
          <span :if={@action[:icon]} class={@action[:icon]}></span>
          <span :if={@action[:label]}>{@action[:label]}</span>
          <.action_badge
            :for={badge <- action_badges(@action)}
            badge={badge}
            class={@badge_class}
            default_color={@badge_default_color}
          />
        </span>
      <% href = @action[:href] -> %>
        <a
          href={href}
          class={["lg-bar-action", @class, @action[:class]]}
          title={@action[:tooltip]}
          data-action-id={@action[:id]}
          phx-click={@action[:phx_click]}
          phx-target={@action[:phx_target]}
          {phx_value_attrs(@action[:phx_value], @event_id)}
        >
          <span :if={@action[:icon]} class={@action[:icon]}></span>
          <span :if={@action[:label]}>{@action[:label]}</span>
          <.action_badge
            :for={badge <- action_badges(@action)}
            badge={badge}
            class={@badge_class}
            default_color={@badge_default_color}
          />
        </a>
      <% true -> %>
        <button
          type="button"
          class={["lg-bar-action", @class, @action[:class]]}
          title={@action[:tooltip]}
          data-action-id={@action[:id]}
          phx-click={@action[:phx_click]}
          phx-target={@action[:phx_target]}
          {phx_value_attrs(@action[:phx_value], @event_id)}
        >
          <span :if={@action[:icon]} class={@action[:icon]}></span>
          <span :if={@action[:label]}>{@action[:label]}</span>
          <.action_badge
            :for={badge <- action_badges(@action)}
            badge={badge}
            class={@badge_class}
            default_color={@badge_default_color}
          />
        </button>
    <% end %>
    """
  end

  # Bar-level badge — sibling of the bar, positioned in pixels against
  # the bar's rectangle (bar.left_px / right_px / row top+row_px). The
  # ~50% offset (-10px = roughly half a 20px pill) gives the badge the
  # familiar "overhanging the corner" look.
  attr :badge, :map, required: true
  attr :corner_index, :integer, required: true
  attr :bar, :map, required: true
  attr :row_px, :integer, required: true
  attr :content_width, :integer, required: true
  attr :event_id, :string, required: true
  attr :class, :string, required: true
  attr :default_color, :string, required: true

  defp bar_badge(assigns) do
    assigns = assign(assigns, :corner, assigns.badge[:corner] || :top_right)

    ~H"""
    <span
      class={[
        "lg-bar-badge",
        @class,
        @badge[:color] || @default_color,
        @badge[:text_color] || Safe.infer_text_color(@badge[:color]),
        @badge[:flash] && "animate-pulse",
        @badge[:class]
      ]}
      style={badge_position_style(@corner, @bar, @row_px, @corner_index, @content_width)}
      data-event-id={@event_id}
      data-badge-corner={@corner}
      data-row-px={@row_px}
    >
      {@badge[:content]}
    </span>
    """
  end

  # Action-button badge — child of the button (the button is `relative`),
  # positioned with negative inset so the badge overhangs the corner.
  attr :badge, :map, required: true
  attr :class, :string, default: nil
  attr :default_color, :string, default: "bg-error"

  defp action_badge(assigns) do
    ~H"""
    <span class={[
      "lg-action-badge",
      @class || badge_default_class(),
      action_badge_corner_class(@badge[:corner]),
      @badge[:color] || @default_color,
      @badge[:text_color] || Safe.infer_text_color(@badge[:color]),
      @badge[:flash] && "animate-pulse",
      @badge[:class]
    ]}>
      {@badge[:content]}
    </span>
    """
  end

  # Expand a values map to phx-value-* keyword pairs, defaulting to
  # event_id when no override is provided so consumers don't have to
  # repeat it in every action.
  defp phx_value_attrs(nil, event_id), do: [{:"phx-value-event-id", event_id}]

  # The event id is ALWAYS exposed as `phx-value-event-id` (hyphen), matching
  # the no-value path and the chevron's `on_toggle_expand` — so a handler reads
  # `%{"event-id" => id}` regardless of whether extra `phx_value` keys were set.
  # Any keys the action supplies are emitted alongside as `phx-value-<key>`.
  defp phx_value_attrs(%{} = values, event_id) do
    extra = for {k, v} <- values, k not in [:event_id, "event-id"], do: {:"phx-value-#{k}", v}
    [{:"phx-value-event-id", event_id} | extra]
  end

  # Status/progress styling is now driven by component attrs applied
  # inline in the template — see `bar_class` / `status_*_class` /
  # `progress_*_class`. Consumers customize via those attrs rather than
  # by patching helper functions.

  # -- Today marker helpers --

  # A bare `Date` today has no time-of-day, so it represents the whole DAY: it's
  # in range when that day OVERLAPS the window, not just when its midnight does.
  # This matters under a sub-day `window_start` (a NaiveDateTime origin), where a
  # Date today's midnight sits before the intra-day origin (`fd < 0`) even though
  # the day's hours fill the window — without this the today line hides and a
  # spurious "← Today" edge pill renders. A precise NaiveDateTime/DateTime today
  # is a single instant, so the point test is correct for it.
  defp today_in_range?(%Date{} = today, {origin, span_days}) do
    fd = frac_days(today, origin)
    fd > -1 and fd < span_days
  end

  defp today_in_range?(today, {origin, span_days}) do
    fd = frac_days(today, origin)
    fd >= 0 and fd < span_days
  end

  # Which edge today sits past, or nil when it's on-screen. Drives the
  # off-screen "Today" directional hint (so the axis needn't stretch to reach
  # a far-away today). Mirrors `today_in_range?`'s Date-is-a-whole-day rule.
  defp today_offscreen_side(%Date{} = today, {origin, span_days}) do
    fd = frac_days(today, origin)

    cond do
      fd <= -1 -> :before
      fd >= span_days -> :after
      true -> nil
    end
  end

  defp today_offscreen_side(today, {origin, span_days}) do
    fd = frac_days(today, origin)

    cond do
      fd < 0 -> :before
      fd >= span_days -> :after
      true -> nil
    end
  end

  # A `Date` today has no time-of-day, so center the marker in its day; a
  # `DateTime`/`NaiveDateTime` "now" lands at its exact position (precise at
  # hour zoom).
  defp today_left_px(%Date{} = today, {origin, _span}, day_px),
    do: x_px(today, origin, day_px) + div(day_px, 2)

  defp today_left_px(today, {origin, _span}, day_px), do: x_px(today, origin, day_px)

  # -- Non-working dates --

  defp non_working_dates(day_markers) do
    day_markers
    |> Enum.filter(fn m -> not m.available end)
    |> Enum.flat_map(fn marker ->
      end_date = Map.get(marker, :end_date) || Date.add(marker.start_date, 1)

      Date.range(marker.start_date, Date.add(end_date, -1))
      |> Enum.to_list()
    end)
    |> MapSet.new()
  end

  # -- Bar tooltip --

  defp bar_title(event) do
    parts = [event.title]

    parts =
      if progress_pct(event) > 0,
        do: parts ++ ["#{round(progress_pct(event))}%"],
        else: parts

    parts =
      if assignee(event),
        do: parts ++ [assignee(event)],
        else: parts

    Enum.join(parts, " — ")
  end

  # -- Toolbar helpers --

  # Today button click handler. Priority:
  #   1. `on_scroll_today` callback — consumer-supplied JS/event name
  #   2. fall back to `JS.dispatch("lg:scroll-today", to: "##{id}")`
  #      consumed by the LgAutoScroll hook
  # Returns nil when neither is available; the button is rendered disabled
  # in that case.
  defp today_click_handler(_id, handler) when not is_nil(handler), do: handler

  defp today_click_handler(id, nil) when is_binary(id) do
    JS.dispatch("lg:scroll-today", to: "##{id}")
  end

  defp today_click_handler(_, _), do: nil

  # The today button can actually scroll iff a custom `on_scroll_today` is
  # given, OR the default `lg:scroll-today` dispatch has a listener — which
  # requires both an `id` (the dispatch target) and `enable_hooks` (so the
  # `LgAutoScroll` hook is attached to that id). Otherwise it's rendered
  # disabled rather than silently doing nothing.
  defp today_button_functional?(on_scroll_today, _id, _enable_hooks)
       when not is_nil(on_scroll_today),
       do: true

  defp today_button_functional?(_on_scroll_today, id, enable_hooks),
    do: is_binary(id) and enable_hooks == true

  defp zoom_label(:min5, _t), do: "5m"
  defp zoom_label(:min15, _t), do: "15m"
  defp zoom_label(:hour, t), do: I18n.label(:hour, t)
  defp zoom_label(:day, t), do: I18n.label(:day, t)
  defp zoom_label(:week, t), do: I18n.label(:week, t)
  defp zoom_label(:month, t), do: I18n.label(:month, t)
  defp zoom_label(other, _t), do: other |> to_string() |> String.capitalize()

  # Offset so edge indicators sit BELOW the column-header row (not on top
  # of the day numbers). The numbers are empirical — toolbar height ≈ 44px
  # at btn-xs + padding; column header ≈ 32px; plus a ~6px visual gap so
  # the pill doesn't butt right up against the header border.
  defp edge_indicator_top_px(true), do: 86
  defp edge_indicator_top_px(false), do: 42

  # -- Date helpers --

  defp to_date(%Date{} = d), do: d
  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)
  defp to_date(_), do: nil

  # True when (date, hour) is the same calendar hour as `now`. `now` is a
  # DateTime/NaiveDateTime (or nil → never). Drives the current-hour column
  # highlight at `:hour` zoom.
  defp hour_is_now?(_date, _hour, nil), do: false

  defp hour_is_now?(date, hour, now),
    do: date == to_date(now) and hour == now.hour

  defp slot_is_now?(_date, _minute_of_day, _minutes_per_slot, nil), do: false

  defp slot_is_now?(date, minute_of_day, minutes_per_slot, now) do
    now_minute = now.hour * 60 + now.minute

    date == to_date(now) and now_minute >= minute_of_day and
      now_minute < minute_of_day + minutes_per_slot
  end

  defp parse_row_height(height) when is_binary(height) do
    case Float.parse(height) do
      {val, "rem"} -> round(val * 16)
      {val, "px"} -> round(val)
      _ -> @default_row_px
    end
  end

  defp parse_row_height(_), do: @default_row_px
end
