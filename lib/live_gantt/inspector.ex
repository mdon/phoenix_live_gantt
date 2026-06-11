defmodule LiveGantt.Inspector do
  @moduledoc """
  Pure-function HTML scraper for Waterfall output. Takes the rendered
  HTML string (as produced by `Waterfall.waterfall/1` →
  `Phoenix.HTML.Safe.to_iodata/1`) and returns a structured geometry
  map.

  Used by tests, the `mix live_gantt.dump` task, and any
  IEx debugging session where "what does this chart actually look
  like?" needs a structured answer rather than blind regex.

  Path-string parsing is delegated to `LiveGantt.PathFormat`,
  which is also what the renderer uses to build paths — so parser and
  builder always speak the same format.

  ## Output shape

      %{
        rows: ["wf-task-1", "wf-task-2", ...],   # event ids in document order
        bars: %{
          "wf-task-1" => %{kind: :bar | :milestone, left: 100, width: 240}
        },
        connectors: [
          %{
            from: "wf-task-1",
            to: "wf-task-2",
            type: :fs | :ss | :ff | :sf,
            critical: bool,
            invalid: bool,
            raw_path: "M 100 20 H 110 V 60 H 156",
            segments: %{kind: :forward | :detour, x1: ..., y1: ..., ...}
          }
        ],
        edges: %{earlier: int, later: int}
      }

  All numeric values are integers (or floats if the path uses decimals).
  """

  alias LiveGantt.PathFormat

  @doc """
  Parse a Waterfall HTML render into a structured geometry map.
  See module doc for the output shape.
  """
  @spec inspect_html(binary()) :: map()
  def inspect_html(html) when is_binary(html) do
    content_width = extract_content_width(html)
    rows = extract_rows(html)
    row_positions = extract_row_positions(html, rows)
    bars = extract_bars(html, row_positions, content_width)
    parent_map = extract_parent_map(html)
    bars = decorate_with_parent_info(bars, parent_map)

    %{
      rows: rows,
      row_positions: row_positions,
      bars: bars,
      parent_map: parent_map,
      subproject_frames: extract_subproject_frames(html, content_width),
      connectors: extract_connectors(html),
      arrowheads: extract_arrowheads(html, content_width),
      edges: extract_edges(html)
    }
  end

  # -- Rows --

  # Label-column entries carry data-event-id; they appear in render order.
  defp extract_rows(html) do
    Regex.scan(~r/lg-label[^>]*data-event-id="([^"]+)"/, html)
    |> Enum.map(fn [_, id] -> id end)
  end

  # Walk the label-column markup in document order, accumulating y as we
  # go. Each `lg-label` div advances y by its height; each
  # `lg-group` header div also advances y. Returns
  # %{event_id => %{top: y, height: h, center: y + h/2, bottom: y + h}}.
  defp extract_row_positions(html, rows) do
    # Match label rows AND group headers, capturing height + (for labels) event-id.
    matches =
      Regex.scan(
        ~r/class="lg-(label|group)[^"]*"\s+style="height: (\d+)px"(?:[^>]*data-event-id="([^"]+)")?/,
        html
      )

    # Group headers come BEFORE their first label row in document order.
    {positions, _y} =
      Enum.reduce(matches, {%{}, 0}, fn match, {acc, y} ->
        case match do
          [_, "label", h_str, id] when id != "" ->
            h = String.to_integer(h_str)
            entry = %{top: y, height: h, center: y + div(h, 2), bottom: y + h}
            {Map.put(acc, id, entry), y + h}

          [_, "group", h_str | _] ->
            h = String.to_integer(h_str)
            {acc, y + h}

          _ ->
            {acc, y}
        end
      end)

    # Defensive: if regex failed to match for some reason, fall back to
    # a 40px stride so geometry checks still work approximately.
    if map_size(positions) == 0 and rows != [] do
      Enum.with_index(rows)
      |> Map.new(fn {id, i} ->
        top = i * 40
        {id, %{top: top, height: 40, center: top + 20, bottom: top + 40}}
      end)
    else
      positions
    end
  end

  # -- Bars + milestones --

  # Bars: left + width + (derived from row_positions) top + bottom
  # for full pixel rectangles. Milestones get an 11px half-width hit box
  # matching `compute_bar_obstacles/5` in the Waterfall.
  # Horizontal geometry renders as PERCENTAGES of the content width (responsive
  # layout). We reconstruct PIXELS (`pct/100 * content_width`) so the Inspector
  # keeps its pixel contract and stays comparable with connector paths (which
  # are still emitted in pixels).
  defp extract_bars(html, row_positions, content_width) do
    bars =
      Regex.scan(
        ~r/class="lg-bar[^"]*"\s+style="left: ([\d.]+)%; width: ([\d.]+)%"[^>]*phx-value-event-id="([^"]+)"/,
        html
      )
      |> Enum.map(fn [_, left, width, id] ->
        {id,
         build_bar(
           :bar,
           id,
           to_px(left, content_width),
           to_px(width, content_width),
           row_positions
         )}
      end)

    milestones =
      Regex.scan(
        ~r/class="lg-milestone[^"]*"\s+style="left: ([\d.]+)%[^"]*"[^>]*phx-value-event-id="([^"]+)"/,
        html
      )
      |> Enum.map(fn [_, left, id] ->
        {id, build_bar(:milestone, id, to_px(left, content_width), 0, row_positions)}
      end)

    Map.new(bars ++ milestones)
  end

  # Both `min-width` occurrences (header time wrapper + timeline column) equal
  # the content width; grab the first.
  defp extract_content_width(html) do
    case Regex.run(~r/min-width: (\d+)px/, html) do
      [_, w] -> String.to_integer(w)
      _ -> 0
    end
  end

  defp to_px(pct_str, content_width) do
    case Float.parse(pct_str) do
      {pct, _} -> round(pct / 100 * content_width)
      :error -> 0
    end
  end

  defp build_bar(:bar, id, left, width, row_positions) do
    pos = Map.get(row_positions, id, %{top: 0, height: 40, bottom: 40})
    # Default Tailwind `top-1 bottom-1` = 4px inset.
    %{
      kind: :bar,
      left: left,
      width: width,
      right: left + width,
      top: pos.top + 4,
      bottom: pos.bottom - 4
    }
  end

  defp build_bar(:milestone, id, left, _width, row_positions) do
    pos = Map.get(row_positions, id, %{top: 0, height: 40, bottom: 40})
    # Milestones render as ~16px diamonds centered on (left, row.center).
    # `width: 0` matches the original API; `hit_box` provides the actual
    # collision rect (11px half-width, matches `compute_bar_obstacles/5`).
    %{
      kind: :milestone,
      left: left,
      width: 0,
      right: left,
      top: pos.top + 4,
      bottom: pos.bottom - 4,
      hit_box: %{left: left - 11, right: left + 11}
    }
  end

  # -- Connectors --

  defp extract_connectors(html) do
    Regex.scan(
      ~r/<path d="(M [^"]+)"[^>]*data-from-id="([^"]+)" data-to-id="([^"]+)" data-type="([^"]+)" data-critical="([^"]+)" data-invalid="([^"]+)"/,
      html
    )
    |> Enum.map(fn [_, d, from, to, type, critical, invalid] ->
      %{
        from: from,
        to: to,
        type: String.to_atom(type),
        critical: critical == "true",
        invalid: invalid == "true",
        raw_path: d,
        segments: parse_path(d)
      }
    end)
  end

  # Path parsing is owned by PathFormat (same module the renderer uses
  # to build paths), so parser and builder stay in sync.
  defp parse_path(d), do: PathFormat.parse(d)

  # -- Arrowheads --

  # Arrowheads render in a separate non-stretched overlay: a `lg-arrowhead`
  # div positioned by `left: P%` (of the content width) + `top: Ypx`, with the
  # connector's from/to ids. Reconstruct the px tip so it can be compared
  # against the connector path's terminal point.
  defp extract_arrowheads(html, content_width) do
    Regex.scan(
      ~r/class="lg-arrowhead[^"]*"\s+style="left: ([\d.]+)%; top: (\d+)px"\s+data-from-id="([^"]+)"\s+data-to-id="([^"]+)"/,
      html
    )
    |> Enum.map(fn [_, left, top, from, to] ->
      %{
        from: from,
        to: to,
        tip_x: to_px(left, content_width),
        tip_y: String.to_integer(top)
      }
    end)
  end

  # -- Edge indicators --

  defp extract_edges(html) do
    %{
      earlier: count_after_class(html, "lg-edge-earlier"),
      later: count_after_class(html, "lg-edge-later")
    }
  end

  defp count_after_class(html, class) do
    case Regex.run(~r/#{class}[^>]*>[^<]*?(\d+)/, html) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  # -- Sub-project metadata --

  # Walk every element carrying `data-event-id` AND `data-parent-id`
  # (bar, label, milestone, badge — they all repeat the same pair) and
  # build a child_id → parent_id map. Used to surface the tree in
  # downstream callers (tests, dump task) without re-walking the
  # original events list.
  defp extract_parent_map(html) do
    Regex.scan(
      ~r/data-event-id="([^"]+)"[^>]*data-parent-id="([^"]+)"/,
      html
    )
    |> Map.new(fn [_, child, parent] -> {child, parent} end)
  end

  # Add `parent_id` and `is_subproject` to each bar entry.
  # `is_subproject` is true iff the bar carries the default
  # `bar_subproject_class` repeating-stripe pattern OR a custom
  # ring around it, signalling it's a roll-up bar.
  defp decorate_with_parent_info(bars, parent_map) do
    Map.new(bars, fn {id, bar} ->
      {id, Map.put(bar, :parent_id, Map.get(parent_map, id))}
    end)
  end

  # Sub-project frames are translucent rectangles drawn in the
  # timeline column behind each EXPANDED sub-project. Extracts
  # their geometry so tests can assert on placement.
  defp extract_subproject_frames(html, content_width) do
    Regex.scan(
      ~r/lg-subproject-frame[^"]*"\s+style="left: ([\d.]+)%; top: (\d+)px; width: ([\d.]+)%; height: (\d+)px;[^"]*background-color: ([^;]+);/,
      html
    )
    |> Enum.map(fn [_, left, top, width, height, bg] ->
      %{
        # left/width render as % of content width; reconstruct px.
        left_px: to_px(left, content_width),
        top_y: String.to_integer(top),
        width: to_px(width, content_width),
        height: String.to_integer(height),
        background_color: String.trim(bg)
      }
    end)
  end

  # -- Convenience helpers (often useful in assertions / dumping) --

  @doc """
  Returns the SOURCE attach y for a connector — the y where the arrow
  emerges from the source bar's edge. Same for both forward and detour
  shapes (it's `segments.y1`).
  """
  def source_attach_y(%{segments: %{y1: y}}), do: y
  def source_attach_y(_), do: nil

  @doc "Returns the TARGET attach y — where the arrow lands at the target."
  def target_attach_y(%{segments: %{y2: y}}), do: y
  def target_attach_y(_), do: nil

  @doc "Returns the arrow tip x (where the arrowhead sits)."
  def arrow_tip_x(%{segments: %{arrow_stop: x}}), do: x
  def arrow_tip_x(_), do: nil

  @doc "All connectors emerging from the given source id."
  def connectors_from(geom, id), do: Enum.filter(geom.connectors, &(&1.from == id))

  @doc "All connectors landing on the given target id."
  def connectors_to(geom, id), do: Enum.filter(geom.connectors, &(&1.to == id))

  @doc "Returns the parent_id of `id`, or nil if it's top-level."
  def parent_of(geom, id), do: Map.get(geom.parent_map, id)

  @doc "Direct children of `id` (one level deep)."
  def children_of(geom, id) do
    geom.parent_map
    |> Enum.filter(fn {_child, parent} -> parent == id end)
    |> Enum.map(fn {child, _} -> child end)
  end

  @doc "True iff `id` is rendered as a sub-project roll-up bar."
  def subproject?(geom, id) do
    Enum.any?(geom.parent_map, fn {_, parent} -> parent == id end)
  end
end
