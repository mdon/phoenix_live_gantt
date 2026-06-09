defmodule LiveGantt.LayoutTest do
  use ExUnit.Case, async: true

  alias LiveGantt.Layout

  defp item(id, duration, parent \\ nil, order \\ 0),
    do: %{id: id, duration: duration, parent: parent, order: order}

  describe "sequential/2 — flat waterfall" do
    test "each item starts where the previous ended (durations as days)" do
      items = [item("a", 2), item("b", 3), item("c", 1)]

      spans = Layout.sequential(items, start: ~D[2026-06-01], parent_id: & &1.parent)

      assert spans["a"] == %{start: ~D[2026-06-01], end: ~D[2026-06-03]}
      assert spans["b"] == %{start: ~D[2026-06-03], end: ~D[2026-06-06]}
      assert spans["c"] == %{start: ~D[2026-06-06], end: ~D[2026-06-07]}
    end

    test "min_span_days keeps zero/short durations a visible bar and non-overlapping" do
      items = [item("a", 0), item("b", 0)]

      spans = Layout.sequential(items, start: ~D[2026-06-01], parent_id: & &1.parent)

      assert spans["a"] == %{start: ~D[2026-06-01], end: ~D[2026-06-02]}
      assert spans["b"] == %{start: ~D[2026-06-02], end: ~D[2026-06-03]}
    end

    test "respects :order over input order" do
      items = [item("late", 1, nil, 2), item("early", 1, nil, 1)]

      spans =
        Layout.sequential(items, start: ~D[2026-06-01], parent_id: & &1.parent, order: & &1.order)

      assert spans["early"].start == ~D[2026-06-01]
      assert spans["late"].start == ~D[2026-06-02]
    end
  end

  describe "sequential/2 — sub-projects" do
    test "a sub-project spans its laid-out children" do
      items = [
        item("p", 0, nil),
        item("c1", 1, "p"),
        item("c2", 1, "p"),
        item("after", 1, nil)
      ]

      spans = Layout.sequential(items, start: ~D[2026-06-01], parent_id: & &1.parent)

      # children laid out under the parent's start
      assert spans["c1"] == %{start: ~D[2026-06-01], end: ~D[2026-06-02]}
      assert spans["c2"] == %{start: ~D[2026-06-02], end: ~D[2026-06-03]}
      # parent spans both children exactly — no spill
      assert spans["p"] == %{start: ~D[2026-06-01], end: ~D[2026-06-03]}
      # the next top-level item starts after the whole sub-project
      assert spans["after"].start == ~D[2026-06-03]
    end

    test "an empty sub-project falls back to its own duration" do
      items = [item("p", 4, nil)]
      spans = Layout.sequential(items, start: ~D[2026-06-01], parent_id: & &1.parent)
      assert spans["p"] == %{start: ~D[2026-06-01], end: ~D[2026-06-05]}
    end

    test "nested sub-projects span transitively" do
      items = [
        item("p", 0, nil),
        item("mid", 0, "p"),
        item("leaf", 2, "mid")
      ]

      spans = Layout.sequential(items, start: ~D[2026-06-01], parent_id: & &1.parent)

      assert spans["leaf"] == %{start: ~D[2026-06-01], end: ~D[2026-06-03]}
      assert spans["mid"] == %{start: ~D[2026-06-01], end: ~D[2026-06-03]}
      assert spans["p"] == %{start: ~D[2026-06-01], end: ~D[2026-06-03]}
    end
  end

  describe "sequential/2 — hour resolution" do
    test "lays NaiveDateTime items out at hour precision with an hour min span" do
      items = [
        %{id: "a", duration: 2, parent: nil, order: 1},
        %{id: "b", duration: 0, parent: nil, order: 2}
      ]

      spans =
        Layout.sequential(items,
          start: ~N[2026-06-01 09:00:00],
          parent_id: & &1.parent,
          order: & &1.order,
          min_span: {:hour, 1},
          advance: fn start, hours, _ -> NaiveDateTime.add(start, hours * 3600, :second) end
        )

      # a: 2h bar 09:00–11:00; b: zero-duration clamped to the 1h min span.
      assert spans["a"] == %{start: ~N[2026-06-01 09:00:00], end: ~N[2026-06-01 11:00:00]}
      assert spans["b"] == %{start: ~N[2026-06-01 11:00:00], end: ~N[2026-06-01 12:00:00]}
    end

    test "a sub-project spans its hour-precise children" do
      items = [
        %{id: "p", duration: 0, parent: nil, order: 1},
        %{id: "c1", duration: 3, parent: "p", order: 1},
        %{id: "c2", duration: 1, parent: "p", order: 2}
      ]

      spans =
        Layout.sequential(items,
          start: ~N[2026-06-01 08:00:00],
          parent_id: & &1.parent,
          order: & &1.order,
          min_span: {:hour, 1},
          advance: fn start, hours, _ -> NaiveDateTime.add(start, hours * 3600, :second) end
        )

      assert spans["c1"] == %{start: ~N[2026-06-01 08:00:00], end: ~N[2026-06-01 11:00:00]}
      assert spans["c2"] == %{start: ~N[2026-06-01 11:00:00], end: ~N[2026-06-01 12:00:00]}
      # parent spans 08:00 → 12:00 (both children), no spill
      assert spans["p"] == %{start: ~N[2026-06-01 08:00:00], end: ~N[2026-06-01 12:00:00]}
    end
  end

  describe "sequential/2 — pluggable advance" do
    test "arity-3 advance can read the item (per-item calendar)" do
      # Weekend-skipping: a duration of N *working* days, skipping Sat/Sun.
      advance = fn start_date, days, _item -> add_working_days(start_date, days) end

      # 2026-06-05 is a Friday.
      items = [item("a", 1), item("b", 1)]

      spans =
        Layout.sequential(items,
          start: ~D[2026-06-05],
          parent_id: & &1.parent,
          advance: advance
        )

      assert spans["a"] == %{start: ~D[2026-06-05], end: ~D[2026-06-08]}
      assert spans["b"].start == ~D[2026-06-08]
    end

    test "accepts a 2-arity advance too" do
      advance = fn date, n -> Date.add(date, n * 2) end

      spans =
        Layout.sequential([item("a", 1)],
          start: ~D[2026-06-01],
          parent_id: & &1.parent,
          advance: advance
        )

      assert spans["a"] == %{start: ~D[2026-06-01], end: ~D[2026-06-03]}
    end
  end

  # Fri + 1 working day -> Mon (skip Sat/Sun).
  defp add_working_days(date, days) do
    Enum.reduce(1..days//1, date, fn _, d ->
      d = Date.add(d, 1)
      d = if Date.day_of_week(d) == 6, do: Date.add(d, 2), else: d
      if Date.day_of_week(d) == 7, do: Date.add(d, 1), else: d
    end)
  end
end
