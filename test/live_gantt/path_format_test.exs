defmodule LiveGantt.PathFormatTest do
  use ExUnit.Case, async: true

  alias LiveGantt.PathFormat

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
end
