defmodule PhoenixLiveGantt.PathFormat do
  @moduledoc """
  Single source of truth for the PhoenixLiveGantt connector path string format.

  Connector paths come in two shape families:

      :forward  — "M x1 y1 H mid V y2 H arrow_stop"
                  3 segments. Used by FS / SS / FF / SF when there's room
                  for a single trunk between source and target.

      :detour   — "M x1 y1 H stem_out V detour_y H stem_in V y2 H arrow_stop"
                  5 segments. Used by :fs when the forward path can't be
                  laid out cleanly (target before source, tight gap, or
                  trunk would pierce intermediate bars).

  Owning both the BUILDER and the PARSER here keeps `PhoenixLiveGantt` (which
  emits paths) and `PhoenixLiveGantt.Inspector` (which parses them for tests
  and the dump task) in sync — if a new shape family is added or the
  format changes, both update at once.

  All numeric inputs/outputs are integers. Decimal coords aren't emitted
  by the renderer today; if that ever changes, extend `parse/1`.
  """

  # ---- Builders (used by the PhoenixLiveGantt renderer) ----

  @doc """
  Build the 3-segment forward path string.

      iex> PathFormat.forward(100, 20, 130, 60, 180)
      "M 100 20 H 130 V 60 H 180"
  """
  @spec forward(integer(), integer(), integer(), integer(), integer()) :: String.t()
  def forward(x1, y1, mid, y2, arrow_stop) do
    "M #{x1} #{y1} H #{mid} V #{y2} H #{arrow_stop}"
  end

  @doc """
  Build the 5-segment detour path string.

      iex> PathFormat.detour(100, 20, 130, 80, 160, 100, 180)
      "M 100 20 H 130 V 80 H 160 V 100 H 180"
  """
  @spec detour(integer(), integer(), integer(), integer(), integer(), integer(), integer()) ::
          String.t()
  def detour(x1, y1, stem_out, detour_y, stem_in, y2, arrow_stop) do
    "M #{x1} #{y1} H #{stem_out} V #{detour_y} H #{stem_in} V #{y2} H #{arrow_stop}"
  end

  # ---- Parser (used by Inspector) ----

  @doc """
  Parse a path d-string into a structured segment map. Returns one of:

      %{kind: :forward, x1: ..., y1: ..., mid: ..., y2: ..., arrow_stop: ...}
      %{kind: :detour,  x1: ..., y1: ..., stem_out: ..., detour_y: ...,
                        stem_in: ..., y2: ..., arrow_stop: ...}
      %{kind: :unknown, raw: <input>}

  All coords are integers (or floats if a decimal slips into the input).
  """
  @spec parse(String.t()) :: map()
  def parse(d) when is_binary(d) do
    cond do
      m = Regex.run(detour_re(), d) ->
        [_, x1, y1, stem_out, detour_y, stem_in, y2, arrow_stop] = m

        %{
          kind: :detour,
          x1: to_n(x1),
          y1: to_n(y1),
          stem_out: to_n(stem_out),
          detour_y: to_n(detour_y),
          stem_in: to_n(stem_in),
          y2: to_n(y2),
          arrow_stop: to_n(arrow_stop)
        }

      m = Regex.run(forward_re(), d) ->
        [_, x1, y1, mid, y2, arrow_stop] = m

        %{
          kind: :forward,
          x1: to_n(x1),
          y1: to_n(y1),
          mid: to_n(mid),
          y2: to_n(y2),
          arrow_stop: to_n(arrow_stop)
        }

      true ->
        %{kind: :unknown, raw: d}
    end
  end

  @doc """
  All absolute `{x, y}` points of an `M`/`H`/`V` path, in order. Works for any
  shape the renderer emits — the 3-segment forward, 5-segment detour, and the
  consolidator's N-segment jog — not just the two canonical regex forms.

      iex> PathFormat.points("M 100 20 H 130 V 60 H 180")
      [{100, 20}, {130, 20}, {130, 60}, {180, 60}]
  """
  @spec points(String.t()) :: [{number(), number()}]
  def points(d) when is_binary(d) do
    d
    |> String.split(~r/\s+/, trim: true)
    |> walk_points({0, 0}, [])
    |> Enum.reverse()
  end

  @doc """
  Terminal point + final-segment direction of any `M`/`H`/`V` path. The
  direction is where the LAST segment travels (`:east`/`:west` for a horizontal
  finish, `:south`/`:north` for vertical, `nil` for a zero-length/degenerate
  finish). Used to place the arrowhead overlay on the shaft's true end.

      iex> PathFormat.terminal("M 100 20 H 130 V 60 H 180")
      %{x: 180, y: 60, dir: :east}
  """
  @spec terminal(String.t()) :: %{x: number(), y: number(), dir: atom() | nil}
  def terminal(d) when is_binary(d) do
    case points(d) do
      [_ | _] = pts ->
        {tx, ty} = List.last(pts)

        dir =
          case Enum.take(pts, -2) do
            [{px, py}, _last] -> segment_dir(px, py, tx, ty)
            _ -> nil
          end

        %{x: tx, y: ty, dir: dir}

      _ ->
        %{x: 0, y: 0, dir: nil}
    end
  end

  defp segment_dir(px, py, tx, ty) do
    cond do
      tx == px and ty == py -> nil
      abs(tx - px) >= abs(ty - py) -> if tx >= px, do: :east, else: :west
      true -> if ty >= py, do: :south, else: :north
    end
  end

  defp walk_points([], _cur, acc), do: acc

  defp walk_points(["M", x, y | rest], _cur, acc) do
    pt = {to_n(x), to_n(y)}
    walk_points(rest, pt, [pt | acc])
  end

  defp walk_points(["H", x | rest], {_cx, cy}, acc) do
    pt = {to_n(x), cy}
    walk_points(rest, pt, [pt | acc])
  end

  defp walk_points(["V", y | rest], {cx, _cy}, acc) do
    pt = {cx, to_n(y)}
    walk_points(rest, pt, [pt | acc])
  end

  defp walk_points([_other | rest], cur, acc), do: walk_points(rest, cur, acc)

  defp forward_re,
    do: ~r/^M ([\d.\-]+) ([\d.\-]+) H ([\d.\-]+) V ([\d.\-]+) H ([\d.\-]+)$/

  defp detour_re,
    do:
      ~r/^M ([\d.\-]+) ([\d.\-]+) H ([\d.\-]+) V ([\d.\-]+) H ([\d.\-]+) V ([\d.\-]+) H ([\d.\-]+)$/

  defp to_n(s) do
    case Integer.parse(s) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(s) do
          {n, _} -> n
          _ -> s
        end
    end
  end
end
