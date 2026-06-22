defmodule PhoenixLiveGantt.PathFormatTest do
  use ExUnit.Case, async: true

  alias PhoenixLiveGantt.PathFormat

  describe "forward/5" do
    test "builds the canonical 3-segment path" do
      assert PathFormat.forward(100, 20, 130, 60, 180) == "M 100 20 H 130 V 60 H 180"
    end
  end

  describe "detour/7" do
    test "builds the canonical 5-segment path" do
      assert PathFormat.detour(100, 20, 130, 80, 160, 100, 180) ==
               "M 100 20 H 130 V 80 H 160 V 100 H 180"
    end
  end

  describe "gutter/9" do
    test "builds the canonical 7-segment outer-gutter path" do
      assert PathFormat.gutter(100, 20, 110, 40, 80, 120, 160, 140, 180) ==
               "M 100 20 H 110 V 40 H 80 V 120 H 160 V 140 H 180"
    end

    test "parse/1 leaves it :unknown (shape is ambiguous with a multi-hop jog)" do
      d = PathFormat.gutter(100, 20, 110, 40, 80, 120, 160, 140, 180)
      assert %{kind: :unknown} = PathFormat.parse(d)
      # ...but the generic walker still reads its true terminal for the arrowhead.
      assert %{x: 180, y: 140, dir: :east} = PathFormat.terminal(d)
    end
  end

  describe "parse/1" do
    test "round-trips a forward path" do
      d = PathFormat.forward(100, 20, 130, 60, 180)

      assert %{kind: :forward, x1: 100, y1: 20, mid: 130, y2: 60, arrow_stop: 180} =
               PathFormat.parse(d)
    end

    test "round-trips a detour path" do
      d = PathFormat.detour(100, 20, 130, 80, 160, 100, 180)

      assert %{
               kind: :detour,
               x1: 100,
               y1: 20,
               stem_out: 130,
               detour_y: 80,
               stem_in: 160,
               y2: 100,
               arrow_stop: 180
             } = PathFormat.parse(d)
    end

    test "returns :unknown for malformed input" do
      assert %{kind: :unknown, raw: "garbage"} = PathFormat.parse("garbage")
    end

    test "handles negative coords (e.g. SS arrows looping past x=0)" do
      d = PathFormat.forward(20, 10, -5, 50, 18)

      assert %{kind: :forward, x1: 20, y1: 10, mid: -5, y2: 50, arrow_stop: 18} =
               PathFormat.parse(d)
    end
  end

  describe "points/1 and terminal/1" do
    test "points/1 enumerates absolute vertices of a forward path" do
      assert PathFormat.points("M 100 20 H 130 V 60 H 180") ==
               [{100, 20}, {130, 20}, {130, 60}, {180, 60}]
    end

    test "terminal/1 returns the last point + final-segment direction (east)" do
      assert %{x: 180, y: 60, dir: :east} = PathFormat.terminal("M 100 20 H 130 V 60 H 180")
    end

    test "terminal/1 sees a westward final segment (e.g. SS / backward)" do
      assert %{x: 40, y: 60, dir: :west} = PathFormat.terminal("M 100 20 H 70 V 60 H 40")
    end

    test "terminal/1 follows the TRUE end of a multi-hop jog, not the canonical y2" do
      # The consolidator emits N-segment jogs PathFormat.parse can't classify.
      # For an UPWARD connector it ends at the source y (y_bot = max(y1,y2)),
      # NOT the target's y — the arrowhead must follow this real terminal.
      d = "M 100 200 H 130 V 170 H 160 V 140 H 190 V 120 H 220"

      assert %{x: 220, y: 120, dir: :east} = PathFormat.terminal(d)
      # ...and the canonical parser indeed can't read it (justifying the
      # generic walker the overlay relies on).
      assert %{kind: :unknown} = PathFormat.parse(d)
    end
  end
end
