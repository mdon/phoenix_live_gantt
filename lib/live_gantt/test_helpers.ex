defmodule LiveGantt.TestHelpers do
  @moduledoc """
  Render, inspect, and assert helpers for the Waterfall view. Replaces
  ad-hoc probe scripts with a one-line call. Used from tests, IEx, and
  the `mix live_gantt.dump` task.

      events = [%LiveGantt.Task{id: "a", start: ~D[2026-04-01], end: ~D[2026-04-05]}]
      html = render_waterfall(events)
      geom = inspect_waterfall(events)
      dump_waterfall(events)        # pretty-prints to stdout

  Pass any waterfall attr as an option:

      render_waterfall(events,
        connectors: [%{from: "a", to: "b"}],
        zoom: :day,
        bus_stagger_outgoing_px: 4
      )

  `:date_range` defaults to a tight range derived from the events.

  Also provides geometry assertions for tests:
    * `assert_lanes_evenly_spaced/3` — catches lane-stagger rounding bugs
    * `assert_source_attaches_inside_bar/2` — catches corner-bleed bugs
    * `assert_arrow_tips_clear_target_bars/2` — catches refX/gap bugs

  Lives in `lib/` (not `test/support/`) because the mix task uses it
  at dev runtime.
  """

  use Phoenix.Component
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias LiveGantt.Inspector

  @doc """
  Render the Waterfall component with the given events and options.
  All component attrs default to their declared defaults; opts override.
  Returns the rendered HTML string.
  """
  @spec render_waterfall([Event.t()], keyword()) :: String.t()
  def render_waterfall(events, opts \\ []) do
    range = Keyword.get(opts, :date_range) || derive_range(events)

    attrs =
      [events: events, date_range: range]
      |> Keyword.merge(Keyword.delete(opts, :date_range))
      |> Map.new()

    assigns = %{attrs: attrs}

    rendered_to_string(~H"<LiveGantt.gantt {@attrs} />")
  end

  @doc "Render then immediately inspect into a structured geometry map."
  @spec inspect_waterfall([Event.t()], keyword()) :: map()
  def inspect_waterfall(events, opts \\ []) do
    events |> render_waterfall(opts) |> Inspector.inspect_html()
  end

  @doc """
  Render, inspect, and pretty-print to stdout. Returns the geometry map
  for further inspection.
  """
  @spec dump_waterfall([Event.t()], keyword()) :: map()
  def dump_waterfall(events, opts \\ []) do
    geom = inspect_waterfall(events, opts)
    print_geometry(geom)
    geom
  end

  # -- Range derivation --

  defp derive_range(events) do
    dates =
      events
      |> Enum.flat_map(fn e ->
        [to_date(e.start), to_date(LiveGantt.Task.effective_end(e))]
      end)
      |> Enum.reject(&is_nil/1)

    case dates do
      [] ->
        today = Date.utc_today()
        Date.range(today, Date.add(today, 30))

      _ ->
        first = Enum.min(dates, Date)
        last = Enum.max(dates, Date)
        # 1-day padding on each side so bars don't sit on the chart's edge
        Date.range(Date.add(first, -1), Date.add(last, 1))
    end
  end

  defp to_date(%Date{} = d), do: d
  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)
  defp to_date(_), do: nil

  # -- Pretty printing --

  defp print_geometry(geom) do
    IO.puts("=== Rows (top → bottom) ===")

    Enum.each(Enum.with_index(geom.rows), fn {id, i} ->
      bar = Map.get(geom.bars, id, %{})
      IO.puts("  #{String.pad_leading("#{i}", 2)}: #{id}#{format_bar(bar)}")
    end)

    IO.puts("\n=== Connectors (#{length(geom.connectors)}) ===")

    Enum.each(geom.connectors, fn c ->
      flags =
        [{c.critical, "critical"}, {c.invalid, "INVALID"}]
        |> Enum.filter(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      flag_str = if flags == [], do: "", else: " [#{Enum.join(flags, ", ")}]"
      IO.puts("  #{c.from} → #{c.to} (#{c.type})#{flag_str}")
      IO.puts("    #{format_segments(c.segments)}")
    end)

    edges = geom.edges

    if edges.earlier > 0 or edges.later > 0 do
      IO.puts("\n=== Edge indicators ===")
      IO.puts("  ← #{edges.earlier} earlier   #{edges.later} later →")
    end
  end

  defp format_bar(%{kind: :bar, left: l, width: w}),
    do: "  bar @ x=#{l}..#{l + w} (#{w}px wide)"

  defp format_bar(%{kind: :milestone, left: l}),
    do: "  ◆ milestone @ x=#{l}"

  defp format_bar(_), do: ""

  defp format_segments(%{kind: :forward, x1: x1, y1: y1, mid: mid, y2: y2, arrow_stop: stop}),
    do: "forward: src=(#{x1},#{y1}) → mid=#{mid} → tgt=(#{stop},#{y2})"

  defp format_segments(%{
         kind: :detour,
         x1: x1,
         y1: y1,
         stem_out: so,
         detour_y: dy,
         stem_in: si,
         y2: y2,
         arrow_stop: stop
       }),
       do:
         "detour:  src=(#{x1},#{y1}) → stem_out=#{so} → detour_y=#{dy} → stem_in=#{si} → tgt=(#{stop},#{y2})"

  defp format_segments(%{kind: :unknown, raw: r}), do: "unknown: #{r}"

  # ============================================================
  # Geometry property assertions — codify visual quality criteria
  # so future regressions get caught automatically.
  # ============================================================

  @doc """
  Assert that all SOURCE attach y values for connectors emerging from
  `source_id` are evenly spaced. Catches lane-stagger rounding bugs.

  Pass `:tolerance_px` (default 0) to allow off-by-N differences in
  spacings (useful for sub-pixel rendering).
  """
  def assert_lanes_evenly_spaced(html, source_id, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance_px, 0)
    geom = Inspector.inspect_html(html)

    ys =
      geom
      |> Inspector.connectors_from(source_id)
      |> Enum.map(&Inspector.source_attach_y/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    case ys do
      [] ->
        raise "assert_lanes_evenly_spaced: no connectors found from #{inspect(source_id)}"

      [_] ->
        :ok

      _ ->
        spacings = Enum.zip(ys, tl(ys)) |> Enum.map(fn {a, b} -> b - a end)
        min_s = Enum.min(spacings)
        max_s = Enum.max(spacings)

        if max_s - min_s > tolerance do
          raise """
          assert_lanes_evenly_spaced: lanes from #{source_id} not evenly spaced.
            Y values: #{inspect(ys)}
            Spacings: #{inspect(spacings)}
            min=#{min_s}, max=#{max_s}, tolerance=#{tolerance}
          """
        end

        :ok
    end
  end

  @doc """
  Assert that every connector's SOURCE attach y falls inside the source
  bar's actual vertical extent (with optional inset for rounded corners).

  Uses Inspector's per-bar `top`/`bottom` (derived from real row
  positions, including group headers) — accurate even when group
  headers shift the row stride.

  `:corner_inset_px` (default 4) — px to inset from bar's top/bottom
  for the rounded-corner area. Defaults match the Waterfall's
  `bus_stagger_corner_clearance_px`.
  """
  def assert_source_attaches_inside_bar(html, opts \\ []) do
    corner_inset = Keyword.get(opts, :corner_inset_px, 4)
    geom = Inspector.inspect_html(html)

    violations =
      Enum.flat_map(geom.connectors, fn c ->
        with %{} = bar <- Map.get(geom.bars, c.from),
             y when is_integer(y) <- Inspector.source_attach_y(c) do
          if y < bar.top + corner_inset or y > bar.bottom - corner_inset do
            [{c.from, c.to, y, bar.top, bar.bottom}]
          else
            []
          end
        else
          _ -> []
        end
      end)

    case violations do
      [] ->
        :ok

      _ ->
        raise """
        assert_source_attaches_inside_bar: #{length(violations)} connector(s)
        attach outside the bar's flat region (corner_inset=#{corner_inset}):
        #{Enum.map_join(violations, "\n", fn {f, t, y, top, bot} -> "  #{f} → #{t}: y=#{y} (bar y=#{top}..#{bot})" end)}
        """
    end
  end

  @doc """
  Assert that no connector's trunk visually pierces an unrelated bar.
  Walks each path's vertical trunk segment and checks that no other
  task's bar rectangle (excluding the connector's own endpoints) sits
  in the trunk's x-column AND overlaps the trunk's y-span.

  Catches the "arrow visibly cuts through a task bar" class of bug
  that `avoid_collisions` is supposed to prevent.

  Pass `:tolerance_px` (default 0) to allow slight overlaps (useful
  for cases where a bar shares an x-edge with the trunk by 1px).
  """
  def assert_no_unrelated_bar_pierced(html, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance_px, 0)
    geom = Inspector.inspect_html(html)

    violations =
      Enum.flat_map(geom.connectors, fn c ->
        trunks = trunk_segments(c)
        check_trunks(trunks, c, geom.bars, tolerance)
      end)

    case violations do
      [] ->
        :ok

      _ ->
        raise """
        assert_no_unrelated_bar_pierced: #{length(violations)} bar piercing(s) detected.
        #{Enum.map_join(violations, "\n", &format_pierce/1)}
        """
    end
  end

  # Returns the path's segments to check for piercing as tagged tuples:
  #   {:v, x, y_top, y_bottom}      — vertical segment at column x
  #   {:h, y, x_left, x_right}      — horizontal segment at row y
  # Forward (3-seg): only one vertical (the trunk). Forward's horizontal
  # segments are at y1 (source row) and y2 (target row), which only
  # touch the source/target bars (excluded from the check).
  # Detour (5-seg): two verticals (stem_out, stem_in) plus the horizontal
  # leg at detour_y. The horizontal leg matters because push_detour can
  # land detour_y inside an unrelated row's bar y-range.
  defp trunk_segments(%{segments: %{kind: :forward, mid: x, y1: y1, y2: y2}}) do
    [{:v, x, min(y1, y2), max(y1, y2)}]
  end

  defp trunk_segments(%{
         segments: %{
           kind: :detour,
           y1: y1,
           stem_out: out,
           detour_y: dy,
           stem_in: in_x,
           y2: y2
         }
       }) do
    [
      {:v, out, min(y1, dy), max(y1, dy)},
      {:v, in_x, min(dy, y2), max(dy, y2)},
      {:h, dy, min(out, in_x), max(out, in_x)}
    ]
  end

  defp trunk_segments(_), do: []

  defp check_trunks(trunks, conn, bars, tolerance) do
    excluded = MapSet.new([conn.from, conn.to])

    Enum.flat_map(trunks, fn segment ->
      Enum.flat_map(bars, fn {bar_id, bar} ->
        if MapSet.member?(excluded, bar_id) do
          []
        else
          if pierces?(segment, bar, tolerance) do
            [
              %{
                from: conn.from,
                to: conn.to,
                segment: segment,
                bar_id: bar_id,
                bar: bar
              }
            ]
          else
            []
          end
        end
      end)
    end)
  end

  # Vertical segment piercing: trunk_x inside bar's x range AND trunk's
  # y span overlaps bar's y range.
  defp pierces?({:v, tx, y_top, y_bot}, bar, tolerance) do
    bar_left = Map.get(bar, :hit_box, bar)[:left] || bar.left
    bar_right = Map.get(bar, :hit_box, bar)[:right] || bar.right

    x_inside? = tx > bar_left + tolerance and tx < bar_right - tolerance
    y_overlap? = y_top < bar.bottom - tolerance and y_bot > bar.top + tolerance

    x_inside? and y_overlap?
  end

  # Horizontal segment piercing: trunk y inside bar's y range AND trunk's
  # x span overlaps bar's x range. Catches the case where push_detour
  # lands `detour_y` inside an unrelated row's bar.
  defp pierces?({:h, ty, x_left, x_right}, bar, tolerance) do
    bar_left = Map.get(bar, :hit_box, bar)[:left] || bar.left
    bar_right = Map.get(bar, :hit_box, bar)[:right] || bar.right

    y_inside? = ty > bar.top + tolerance and ty < bar.bottom - tolerance
    x_overlap? = x_left < bar_right - tolerance and x_right > bar_left + tolerance

    y_inside? and x_overlap?
  end

  defp format_pierce(%{from: f, to: t, segment: {:v, tx, _, _}, bar_id: bid, bar: bar}) do
    "  #{f} → #{t}: vertical x=#{tx} pierces bar '#{bid}' (x=#{bar.left}..#{bar.right}, y=#{bar.top}..#{bar.bottom})"
  end

  defp format_pierce(%{from: f, to: t, segment: {:h, ty, xl, xr}, bar_id: bid, bar: bar}) do
    "  #{f} → #{t}: horizontal y=#{ty} (x=#{xl}..#{xr}) pierces bar '#{bid}' (x=#{bar.left}..#{bar.right}, y=#{bar.top}..#{bar.bottom})"
  end

  @doc """
  Assert every connector's path consists only of axis-aligned segments
  (pure horizontal `H` or vertical `V` moves from the initial M point).
  Catches malformed paths or unexpected shape families.
  """
  def assert_paths_axis_aligned(html) do
    geom = Inspector.inspect_html(html)

    violations =
      Enum.flat_map(geom.connectors, fn c ->
        case c.segments.kind do
          :forward -> []
          :detour -> []
          :unknown -> [{c.from, c.to, c.segments.raw}]
        end
      end)

    case violations do
      [] ->
        :ok

      _ ->
        raise """
        assert_paths_axis_aligned: #{length(violations)} non-axis-aligned path(s).
        #{Enum.map_join(violations, "\n", fn {f, t, raw} -> "  #{f} → #{t}: #{raw}" end)}
        """
    end
  end

  @doc """
  Assert all numeric path coordinates are non-negative. Negative coords
  mean a path went off the chart's left/top edge — usually a bug.

  Pass `:allow_negative` to skip (some edge cases legitimately do go
  negative, e.g., :ss arrows near x=0).
  """
  def assert_paths_have_valid_coords(html, opts \\ []) do
    if Keyword.get(opts, :allow_negative, false) do
      :ok
    else
      geom = Inspector.inspect_html(html)

      violations =
        Enum.flat_map(geom.connectors, fn c ->
          coords = path_coords(c.segments)
          negatives = Enum.filter(coords, &(is_number(&1) and &1 < 0))
          if negatives == [], do: [], else: [{c.from, c.to, negatives}]
        end)

      case violations do
        [] ->
          :ok

        _ ->
          raise """
          assert_paths_have_valid_coords: #{length(violations)} path(s) with negative coords.
          #{Enum.map_join(violations, "\n", fn {f, t, ns} -> "  #{f} → #{t}: #{inspect(ns)}" end)}
          """
      end
    end
  end

  defp path_coords(%{kind: :forward, x1: a, y1: b, mid: c, y2: d, arrow_stop: e}),
    do: [a, b, c, d, e]

  defp path_coords(%{
         kind: :detour,
         x1: a,
         y1: b,
         stem_out: c,
         detour_y: d,
         stem_in: e,
         y2: f,
         arrow_stop: g
       }),
       do: [a, b, c, d, e, f, g]

  defp path_coords(_), do: []

  @doc """
  Assert that every detour path satisfies the geometric invariants the
  Waterfall's stem-shifting logic relies on:

    * `stem_out > x1` — source-side stem must be strictly east of the
      source bar's reference x (FS shape requirement).
    * `stem_in < arrow_stop` — target-side stem must be strictly west of
      the arrow tip (FS approach requirement).

  Catches regressions in `maybe_shift_stem_out` / `maybe_shift_stem_in`
  where a stem could be shifted to an x that breaks the shape's
  geometric validity.
  """
  def assert_detour_invariants_hold(html) do
    geom = Inspector.inspect_html(html)

    violations =
      Enum.flat_map(geom.connectors, fn c ->
        case c.segments do
          %{kind: :detour, x1: x1, stem_out: so, stem_in: si, arrow_stop: stop} ->
            issues = []

            issues =
              if so > x1,
                do: issues,
                else: [{c.from, c.to, "stem_out=#{so} must be > x1=#{x1}"} | issues]

            issues =
              if si < stop,
                do: issues,
                else: [{c.from, c.to, "stem_in=#{si} must be < arrow_stop=#{stop}"} | issues]

            issues

          _ ->
            []
        end
      end)

    case violations do
      [] ->
        :ok

      _ ->
        raise """
        assert_detour_invariants_hold: #{length(violations)} detour shape violation(s).
        #{Enum.map_join(violations, "\n", fn {f, t, msg} -> "  #{f} → #{t}: #{msg}" end)}
        """
    end
  end

  @doc """
  Run every geometry assertion against the given html and return a list
  of issues found. Each issue is `{name, exception_message}`. Useful as
  a one-stop "is this render sane?" check.

  Pass `:opts_for` to override per-assertion options:

      find_geometry_issues(html,
        opts_for: %{
          assert_arrow_tips_clear_target_bars: [min_gap_px: 2]
        }
      )
  """
  def find_geometry_issues(html, opts \\ []) do
    overrides = Keyword.get(opts, :opts_for, %{})

    [
      {:paths_axis_aligned, fn -> assert_paths_axis_aligned(html) end},
      {:paths_valid_coords,
       fn ->
         assert_paths_have_valid_coords(
           html,
           Map.get(overrides, :assert_paths_have_valid_coords, [])
         )
       end},
      {:no_pierced_bars,
       fn ->
         assert_no_unrelated_bar_pierced(
           html,
           Map.get(overrides, :assert_no_unrelated_bar_pierced, [])
         )
       end},
      {:source_attaches_inside_bar,
       fn ->
         assert_source_attaches_inside_bar(
           html,
           Map.get(overrides, :assert_source_attaches_inside_bar, [])
         )
       end},
      {:arrow_tips_clear_targets,
       fn ->
         assert_arrow_tips_clear_target_bars(
           html,
           Map.get(overrides, :assert_arrow_tips_clear_target_bars, [])
         )
       end},
      {:detour_invariants, fn -> assert_detour_invariants_hold(html) end}
    ]
    |> Enum.flat_map(fn {name, fun} ->
      try do
        fun.()
        []
      rescue
        e in RuntimeError -> [{name, Exception.message(e)}]
      end
    end)
  end

  @doc """
  Compare two geometry maps and return a structured diff describing
  what changed. Useful for "I changed X — what else moved?" workflows.

      before = inspect_waterfall(events)
      # ... change something ...
      after = inspect_waterfall(events)
      diff_waterfalls(before, after)
      # %{
      #   row_order: %{changed: false} | %{from: [...], to: [...]},
      #   connectors: %{added: [...], removed: [...], changed: [...]},
      #   edges: %{earlier_delta: int, later_delta: int}
      # }
  """
  def diff_waterfalls(before_geom, after_geom) do
    %{
      row_order: row_order_diff(before_geom.rows, after_geom.rows),
      connectors: connector_diffs(before_geom.connectors, after_geom.connectors),
      edges: edge_diffs(before_geom.edges, after_geom.edges)
    }
  end

  defp row_order_diff(before, after_rows) when before == after_rows, do: %{changed: false}
  defp row_order_diff(before, after_rows), do: %{changed: true, from: before, to: after_rows}

  defp connector_diffs(before, after_conns) do
    by_key = fn list ->
      Map.new(list, fn c -> {{c.from, c.to, c.type}, c} end)
    end

    bm = by_key.(before)
    am = by_key.(after_conns)

    added = Enum.filter(Map.keys(am), &(not Map.has_key?(bm, &1)))
    removed = Enum.filter(Map.keys(bm), &(not Map.has_key?(am, &1)))

    changed =
      Enum.flat_map(bm, fn {key, b} ->
        case Map.get(am, key) do
          nil ->
            []

          a ->
            if a.segments == b.segments,
              do: [],
              else: [{key, segments_delta(b.segments, a.segments)}]
        end
      end)

    %{added: added, removed: removed, changed: changed}
  end

  # Compute per-field delta between two segment maps. Only includes
  # fields that actually changed.
  defp segments_delta(before, after_seg) when before.kind != after_seg.kind do
    %{kind_changed: %{from: before.kind, to: after_seg.kind}}
  end

  defp segments_delta(before, after_seg) do
    before
    |> Enum.flat_map(fn {k, v_before} ->
      v_after = Map.get(after_seg, k)

      if v_before != v_after do
        [{k, %{from: v_before, to: v_after, delta: maybe_delta(v_before, v_after)}}]
      else
        []
      end
    end)
    |> Map.new()
  end

  defp maybe_delta(a, b) when is_number(a) and is_number(b), do: b - a
  defp maybe_delta(_, _), do: nil

  defp edge_diffs(before, after_edges) do
    %{
      earlier_delta: after_edges.earlier - before.earlier,
      later_delta: after_edges.later - before.later
    }
  end

  @doc """
  Assert that every connector's arrow tip clears the target bar by at
  least `:min_gap_px` (default 1). For non-FS types or when the target
  is on a different x-side, this is best-effort: only FS arrows
  (target_entry=:west) are checked since their geometry is most
  predictable.
  """
  def assert_arrow_tips_clear_target_bars(html, opts \\ []) do
    min_gap = Keyword.get(opts, :min_gap_px, 1)
    geom = Inspector.inspect_html(html)

    violations =
      geom.connectors
      |> Enum.filter(&(&1.type == :fs))
      |> Enum.flat_map(fn c ->
        with %{} = bar <- Map.get(geom.bars, c.to),
             tip when is_integer(tip) <- Inspector.arrow_tip_x(c) do
          gap = bar.left - tip

          if gap < min_gap do
            [{c.from, c.to, tip, bar.left, gap}]
          else
            []
          end
        else
          _ -> []
        end
      end)

    case violations do
      [] ->
        :ok

      _ ->
        raise """
        assert_arrow_tips_clear_target_bars: #{length(violations)} arrow tip(s)
        too close to / inside the target bar (min_gap=#{min_gap}):
        #{Enum.map_join(violations, "\n", fn {f, t, tip, edge, g} -> "  #{f} → #{t}: tip=#{tip}, target.left=#{edge}, gap=#{g}" end)}
        """
    end
  end
end
