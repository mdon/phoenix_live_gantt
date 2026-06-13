defmodule PhoenixLiveGantt.InspectorTest do
  use ExUnit.Case, async: true

  alias PhoenixLiveGantt.Inspector
  alias PhoenixLiveGantt.TestHelpers

  describe "inspect_html/1" do
    test "extracts row order in document order" do
      events = [
        %PhoenixLiveGantt.Task{
          id: "z",
          start: ~D[2026-04-01],
          end: ~D[2026-04-02],
          color: "bg-primary"
        },
        %PhoenixLiveGantt.Task{
          id: "a",
          start: ~D[2026-04-03],
          end: ~D[2026-04-04],
          color: "bg-primary"
        }
      ]

      geom = TestHelpers.inspect_waterfall(events)

      # Order is by start date, not by id alphabetical.
      assert geom.rows == ["z", "a"]
    end

    test "extracts bar geometries for non-milestone events" do
      events = [
        %PhoenixLiveGantt.Task{
          id: "x",
          start: ~D[2026-04-01],
          end: ~D[2026-04-08],
          color: "bg-primary"
        }
      ]

      geom = TestHelpers.inspect_waterfall(events)

      assert %{kind: :bar, left: l, width: w} = geom.bars["x"]
      assert is_integer(l)
      assert is_integer(w) and w > 0
    end

    test "extracts milestone geometries with width 0" do
      events = [
        %PhoenixLiveGantt.Task{
          id: "ms",
          start: ~D[2026-04-15],
          end: ~D[2026-04-15],
          color: "bg-primary",
          icon: "◆"
        }
      ]

      geom = TestHelpers.inspect_waterfall(events)

      assert %{kind: :milestone, left: _, width: 0} = geom.bars["ms"]
    end

    test "parses a forward (3-segment) connector path into segment fields" do
      events = [
        %PhoenixLiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %PhoenixLiveGantt.Task{
          id: "b",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-primary"
        }
      ]

      geom =
        TestHelpers.inspect_waterfall(events,
          connectors: [%{from: "a", to: "b"}]
        )

      assert [conn] = geom.connectors
      assert conn.from == "a"
      assert conn.to == "b"
      assert conn.type == :fs
      assert %{kind: :forward, x1: _, y1: _, mid: _, y2: _, arrow_stop: _} = conn.segments
    end

    test "parses a 5-segment detour path (backward FS conflict)" do
      events = [
        # Source ends AFTER target starts → backward FS
        %PhoenixLiveGantt.Task{
          id: "src",
          start: ~D[2026-04-10],
          end: ~D[2026-04-20],
          color: "bg-primary"
        },
        %PhoenixLiveGantt.Task{
          id: "tgt",
          start: ~D[2026-04-01],
          end: ~D[2026-04-08],
          color: "bg-primary"
        }
      ]

      geom =
        TestHelpers.inspect_waterfall(events,
          connectors: [%{from: "src", to: "tgt"}]
        )

      assert [conn] = geom.connectors
      assert conn.invalid == true

      assert %{
               kind: :detour,
               x1: _,
               y1: _,
               stem_out: _,
               detour_y: _,
               stem_in: _,
               y2: _,
               arrow_stop: _
             } = conn.segments
    end

    test "extracts edge indicator counts when out-of-range events exist" do
      events = [
        %PhoenixLiveGantt.Task{
          id: "in",
          start: ~D[2026-05-15],
          end: ~D[2026-05-20],
          color: "bg-primary"
        },
        %PhoenixLiveGantt.Task{
          id: "before",
          start: ~D[2026-01-01],
          end: ~D[2026-01-05],
          color: "bg-primary"
        },
        %PhoenixLiveGantt.Task{
          id: "after",
          start: ~D[2026-12-01],
          end: ~D[2026-12-10],
          color: "bg-primary"
        }
      ]

      range = Date.range(~D[2026-05-01], ~D[2026-05-30])
      geom = TestHelpers.inspect_waterfall(events, date_range: range)

      assert geom.edges.earlier == 1
      assert geom.edges.later == 1
    end

    test "marks critical connectors" do
      events = [
        %PhoenixLiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %PhoenixLiveGantt.Task{
          id: "b",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-primary"
        }
      ]

      geom =
        TestHelpers.inspect_waterfall(events,
          connectors: [%{from: "a", to: "b", critical: true}]
        )

      assert [%{critical: true, invalid: false}] = geom.connectors
    end
  end

  describe "convenience helpers" do
    test "connectors_from + connectors_to filter by id" do
      events = [
        %PhoenixLiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %PhoenixLiveGantt.Task{
          id: "b",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-primary"
        },
        %PhoenixLiveGantt.Task{
          id: "c",
          start: ~D[2026-04-20],
          end: ~D[2026-04-25],
          color: "bg-primary"
        }
      ]

      geom =
        TestHelpers.inspect_waterfall(events,
          connectors: [
            %{from: "a", to: "b"},
            %{from: "b", to: "c"}
          ]
        )

      assert [%{to: "b"}] = Inspector.connectors_from(geom, "a")
      assert [%{from: "a"}] = Inspector.connectors_to(geom, "b")
      assert [] = Inspector.connectors_to(geom, "a")
    end
  end
end
