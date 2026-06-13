defmodule PhoenixLiveGantt.Task do
  @moduledoc """
  A Gantt task — one row in the chart, rendered as a horizontal bar
  on the time axis.

  The struct intentionally carries ONLY Gantt-relevant fields. Use
  the `:extra` map for everything else — badges, action buttons,
  sub-project metadata, custom rendering hints, application-specific
  data — without bloating the core type.

  ## Required fields

    * `:id` — unique identifier within the chart (string or atom)
    * `:start` — `Date` (or `DateTime` / `NaiveDateTime` if you want
      time-of-day precision later)

  ## Optional schedule fields

    * `:end` — date the task ends.
      * `nil` AND no children → milestone (zero-duration; renders as
        a diamond)
      * `nil` AND has children (via `extra.parent_id` on other tasks)
        → date range is rolled up from descendants
      * otherwise → bar spans `start..end`

  ## Display

    * `:title` — label rendered in the sidebar
    * `:description` — optional longer text (not rendered by default)
    * `:color` — background CSS class (e.g. `"bg-primary"`)
    * `:text_color` — override CSS class; falls back to a contrast
      pick from `:color`
    * `:icon` — short inline glyph rendered next to the title
    * `:class` — extra CSS classes appended to the bar

  ## Project metadata

    * `:category` — phase / group label; tasks sharing a category
      cluster under a group header in the sidebar
    * `:status` — one of `:active`, `:tentative`, `:cancelled`,
      `:pending_approval`, `:blocked`, `:no_show` — drives bar
      opacity / line-through / pulse / etc.
    * `:progress_pct` — completion % (0-100); fills the bar
    * `:assignee` — owner name; shown in popover subtitle

  ## Extra map keys recognised by the renderer

    * `parent_id` — id of another task. If set, this task is a child
      of the referenced sub-project; the parent rolls up over its
      children's date range and can be expanded/collapsed.
    * `badges` — list of `%{content, corner, color, flash, ...}`
      maps drawn in the bar's corners.
    * `actions` — list of `%{icon, tooltip, phx_click, ...}` maps
      rendered as buttons inside the click popover.
    * `bus_stagger_outgoing_px` / `bus_stagger_incoming_px` —
      per-task override for the connector stagger width.
    * `bus_attach_mode` — per-task override for which side of the bar
      arrows connect to.

  Anything you put in `:extra` that the renderer doesn't recognise
  is silently passed through, so consumers can stuff their own
  metadata next to it freely.
  """

  defstruct [
    # Identity
    :id,

    # Content
    :title,
    :description,

    # Schedule
    :start,
    :end,

    # Display
    :color,
    :text_color,
    :icon,
    :class,

    # Project metadata
    :category,
    :assignee,
    :progress_pct,

    # Defaults
    status: :active,
    extra: %{}
  ]

  @type status ::
          :active | :tentative | :cancelled | :pending_approval | :blocked | :no_show

  @type t :: %__MODULE__{
          id: term(),
          title: String.t() | nil,
          description: String.t() | nil,
          start: Date.t() | DateTime.t() | NaiveDateTime.t() | nil,
          end: Date.t() | DateTime.t() | NaiveDateTime.t() | nil,
          color: String.t() | nil,
          text_color: String.t() | nil,
          icon: String.t() | nil,
          class: String.t() | nil,
          category: String.t() | nil,
          assignee: String.t() | nil,
          progress_pct: number() | nil,
          status: status(),
          extra: map()
        }

  @doc """
  Returns the effective end of a task — what the renderer uses to
  compute the bar's right edge. Handles three cases:

    * Explicit `:end` set → returned as-is.
    * `:end` is nil with a `Date` start → start + 1 day (so a
      one-day task gets a visible bar).
    * `:end` is nil with a `DateTime` / `NaiveDateTime` start → start
      + 30 minutes (matches calendar semantics for time-of-day tasks).
  """
  @spec effective_end(t()) :: Date.t() | DateTime.t() | NaiveDateTime.t() | nil
  def effective_end(%__MODULE__{end: end_time}) when not is_nil(end_time), do: end_time
  def effective_end(%__MODULE__{start: %Date{} = start}), do: Date.add(start, 1)

  def effective_end(%__MODULE__{start: %DateTime{} = start}),
    do: DateTime.add(start, 30 * 60, :second)

  def effective_end(%__MODULE__{start: %NaiveDateTime{} = start}),
    do: NaiveDateTime.add(start, 30 * 60, :second)

  def effective_end(_), do: nil

  @doc """
  Convenience constructor: `PhoenixLiveGantt.Task.new("id", start_date, opts)`.
  """
  @spec new(term(), term(), keyword()) :: t()
  def new(id, start, opts \\ []) do
    struct(__MODULE__, [{:id, id}, {:start, start} | opts])
  end
end
