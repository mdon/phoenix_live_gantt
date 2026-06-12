defmodule LiveGantt.Layout do
  @moduledoc """
  Optional layout helper for the common "I have durations, not dates" case.

  `LiveGantt.gantt/1` is render-only — it draws bars from `start`/`end` **dates**.
  Many domains (project tasks, production steps, itineraries) instead have a
  *duration* + an *order* + maybe *nested sub-projects*, and no per-item dates.
  `sequential/2` does that translation once, correctly, so every consumer
  doesn't re-implement (and re-bug) it:

    * each item starts where the previous sibling ended (a waterfall),
    * a sub-project spans its laid-out children (its bar/frame always contains
      them — no spill),
    * every bar is at least `:min_span` long, so short items stay visible and
      siblings never overlap.

  The calendar math — how a duration advances a date/time across weekends,
  working hours, or holidays — is **yours**, supplied via the `:advance`
  callback. That keeps LiveGantt domain-agnostic: it never assumes what a
  "duration" means.

  Works at whatever resolution your `:start`/`:advance` use: pass `Date`s for a
  day-level waterfall, or `NaiveDateTime`/`DateTime` (with `min_span: {:hour, 1}`)
  for hour-precise layout that pairs with `:hour` zoom.

  ## Deliberately out of scope

  This is layout, not a scheduler. It does NOT do dependency-driven scheduling,
  critical path, resource leveling, "start no earlier than" / "must finish by"
  constraints, lag/lead, or working-hour models. If you need those, compute your
  own dates and pass them to `LiveGantt.gantt/1` directly.

  ## Example

      layout =
        LiveGantt.Layout.sequential(assignments,
          start: ~D[2026-06-01],
          id: & &1.uuid,
          parent_id: & &1.child_parent_uuid,
          duration: & &1.estimated_hours,
          order: & &1.position,
          advance: fn start_date, hours, assignment ->
            # your weekend/working-calendar math
            MyCalendar.add_working(start_date, hours, assignment.counts_weekends)
          end
        )

      events =
        Enum.map(assignments, fn a ->
          %{start: s, end: e} = layout[a.uuid]
          %LiveGantt.Task{id: a.uuid, title: a.title, start: s, end: e, extra: %{parent_id: a.child_parent_uuid}}
        end)
  """

  @type id :: term()
  @type item :: term()
  @type temporal :: Date.t() | NaiveDateTime.t() | DateTime.t()
  @type span :: %{start: temporal(), end: temporal()}

  @max_depth 64

  @doc """
  Lays `items` out into `%{id => %{start: Date.t(), end: Date.t()}}`.

  `end` is exclusive, matching `LiveGantt.gantt/1` (a one-day bar is
  `start..start+1`). Every id in `items` appears in the result, including
  sub-project parents (sized to span their children). Items whose `parent_id`
  forms a cycle, points at themselves, or nests past the internal depth cap are
  laid out flat after the main chain rather than dropped — so `result[id]` is
  always safe.

  ## Options

    * `:start` (required) — the first top-level item's start. A `Date` for day
      layouts; a `NaiveDateTime`/`DateTime` for hour/minute precision (the
      output `start`/`end` preserve the type your `:advance` returns).
    * `:id` — `(item -> id)`. Default `& &1.id`.
    * `:parent_id` — `(item -> id | nil)`. Default `fn _ -> nil end`. An item
      whose parent id is `nil` (or not present among `items`) is a top-level
      root; an item that others point at via this is a sub-project.
    * `:duration` — `(item -> term)`. Default `& &1.duration`. The value is
      opaque to LiveGantt and handed straight to `:advance`.
    * `:order` — `(item -> Enum.sort_by key)`. Default keeps input order
      (siblings are otherwise laid out in the order given).
    * `:advance` — `(start, duration, item -> end)` (a 2-arity
      `(start, duration)` function is also accepted). Default treats the
      duration as a whole number of calendar days (`Date.add/2`). For hour
      precision, return a `NaiveDateTime`/`DateTime`. Plug your
      weekend/working-calendar here.
    * `:min_span` — minimum bar length as `{:day | :hour | :minute | :second, n}`
      (or a bare integer = days). Default `{:day, 1}`. Use `{:hour, 1}` for
      hour layouts so a zero-duration item still gets a one-hour bar.
    * `:min_span_days` — shorthand for `min_span: {:day, n}`. Default `1`.
  """
  @spec sequential([item], keyword()) :: %{id => span}
  def sequential(items, opts) when is_list(items) do
    start = Keyword.fetch!(opts, :start)
    id_fun = Keyword.get(opts, :id, & &1.id)
    parent_fun = Keyword.get(opts, :parent_id, fn _ -> nil end)
    dur_fun = Keyword.get(opts, :duration, & &1.duration)
    order_fun = Keyword.get(opts, :order, fn _ -> 0 end)
    min_span = Keyword.get(opts, :min_span, {:day, Keyword.get(opts, :min_span_days, 1)})
    advance = normalize_advance(Keyword.get(opts, :advance))

    ids = MapSet.new(items, id_fun)

    children =
      Enum.group_by(items, fn it ->
        pid = parent_fun.(it)
        if not is_nil(pid) and MapSet.member?(ids, pid), do: pid, else: :__root__
      end)

    ctx = %{
      children: children,
      id: id_fun,
      dur: dur_fun,
      order: order_fun,
      advance: advance,
      min_span: min_span
    }

    {spans, cursor} = walk(Map.get(children, :__root__, []), start, ctx, 0, %{})

    # Honor the "every id appears" contract: any item the tree walk never reached
    # — a `parent_id` cycle (a→b→a), a self-parent, or nesting past `@max_depth`
    # — would otherwise be silently dropped, and the consumer's `layout[id]`
    # MatchErrors far from the cause. Lay those out flat (no recursion), in order,
    # appended after the main chain. Passing `depth: @max_depth` disables the
    # sub-tree descent so a cycle can't re-trigger the same drop.
    missing = Enum.reject(items, &Map.has_key?(spans, id_fun.(&1)))
    {spans, _cursor} = walk(missing, cursor, ctx, @max_depth, spans)
    spans
  end

  defp walk(items, cursor, ctx, depth, acc) do
    items
    |> Enum.sort_by(ctx.order)
    |> Enum.reduce({acc, cursor}, fn it, {acc, cur} ->
      id = ctx.id.(it)
      kids = Map.get(ctx.children, id, [])

      {span_end, acc} =
        if kids != [] and depth < @max_depth do
          # Sub-project: lay children out first (anchored at this item's start),
          # then size the bar to span them.
          {child_acc, child_end} = walk(kids, cur, ctx, depth + 1, acc)
          {child_end, child_acc}
        else
          {ctx.advance.(cur, ctx.dur.(it), it), acc}
        end

      e = clamp_end(cur, span_end, ctx.min_span)
      {Map.put(acc, id, %{start: cur, end: e}), e}
    end)
  end

  # End must be at least `min_span` past start (so sub-day items stay a visible
  # bar and siblings can't share a start instant and overlap). Works in whatever
  # temporal type the cursor is — `Date` for day layouts, `NaiveDateTime` /
  # `DateTime` for hour/minute layouts.
  defp clamp_end(start, raw_end, min_span) do
    floor = add_span(start, min_span)
    if temporal_compare(raw_end, floor) == :lt, do: floor, else: raw_end
  end

  # `min_span` is `{:day | :hour | :minute | :second, n}` (or a bare integer =
  # days). Adding a sub-day span to a `Date` promotes it to a `NaiveDateTime`.
  defp add_span(t, n) when is_integer(n), do: add_span(t, {:day, n})
  defp add_span(%Date{} = d, {:day, n}), do: Date.add(d, n)
  defp add_span(%Date{} = d, span), do: add_span(NaiveDateTime.new!(d, ~T[00:00:00]), span)

  defp add_span(%NaiveDateTime{} = t, span), do: NaiveDateTime.add(t, span_seconds(span), :second)
  defp add_span(%DateTime{} = t, span), do: DateTime.add(t, span_seconds(span), :second)

  defp span_seconds({:day, n}), do: n * 86_400
  defp span_seconds({:hour, n}), do: n * 3_600
  defp span_seconds({:minute, n}), do: n * 60
  defp span_seconds({:second, n}), do: n

  defp temporal_compare(%Date{} = a, %Date{} = b), do: Date.compare(a, b)

  defp temporal_compare(%NaiveDateTime{} = a, %NaiveDateTime{} = b),
    do: NaiveDateTime.compare(a, b)

  defp temporal_compare(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  defp temporal_compare(a, b), do: NaiveDateTime.compare(as_naive(a), as_naive(b))

  defp as_naive(%Date{} = d), do: NaiveDateTime.new!(d, ~T[00:00:00])
  defp as_naive(%NaiveDateTime{} = t), do: t
  defp as_naive(%DateTime{} = t), do: DateTime.to_naive(t)

  defp normalize_advance(nil), do: fn date, duration, _item -> Date.add(date, duration) end
  defp normalize_advance(fun) when is_function(fun, 3), do: fun
  defp normalize_advance(fun) when is_function(fun, 2), do: fn d, n, _ -> fun.(d, n) end
end
