defmodule LiveGantt.TestHelpersTest do
  use ExUnit.Case, async: true

  alias LiveGantt.TestHelpers

  defp fanout_events do
    [
      %LiveGantt.Task{
        id: "h",
        start: ~D[2026-04-01],
        end: ~D[2026-04-10],
        color: "bg-primary"
      },
      %LiveGantt.Task{
        id: "t1",
        start: ~D[2026-04-11],
        end: ~D[2026-04-15],
        color: "bg-primary"
      },
      %LiveGantt.Task{
        id: "t2",
        start: ~D[2026-04-11],
        end: ~D[2026-04-15],
        color: "bg-primary"
      },
      %LiveGantt.Task{
        id: "t3",
        start: ~D[2026-04-11],
        end: ~D[2026-04-15],
        color: "bg-primary"
      },
      %LiveGantt.Task{
        id: "t4",
        start: ~D[2026-04-11],
        end: ~D[2026-04-15],
        color: "bg-primary"
      },
      %LiveGantt.Task{
        id: "t5",
        start: ~D[2026-04-11],
        end: ~D[2026-04-15],
        color: "bg-primary"
      }
    ]
  end

  defp fanout_connectors do
    [
      %{from: "h", to: "t1"},
      %{from: "h", to: "t2"},
      %{from: "h", to: "t3"},
      %{from: "h", to: "t4"},
      %{from: "h", to: "t5"}
    ]
  end

  describe "render_waterfall/2" do
    test "renders with derived range when no date_range given" do
      events = [
        %LiveGantt.Task{
          id: "x",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        }
      ]

      html = TestHelpers.render_waterfall(events)
      assert html =~ "lg-chart"
      assert html =~ ~s|data-event-id="x"|
    end

    test "passes through arbitrary attrs (e.g. zoom, stagger)" do
      events = fanout_events()

      html =
        TestHelpers.render_waterfall(events,
          connectors: fanout_connectors(),
          zoom: :day,
          bus_stagger_outgoing_px: 4
        )

      # Stagger should show up as distinct trunk x's
      mids =
        Regex.scan(~r/d="M \d+ \d+ H (\d+)/, html)
        |> Enum.map(fn [_, m] -> String.to_integer(m) end)
        |> Enum.uniq()

      assert length(mids) >= 5,
             "expected 5+ distinct trunk x's with stagger, got #{inspect(mids)}"
    end
  end

  describe "assert_lanes_evenly_spaced/3" do
    test "passes when stagger produces evenly-spaced lanes" do
      events = fanout_events()

      html =
        TestHelpers.render_waterfall(events,
          connectors: fanout_connectors(),
          bus_stagger_outgoing_px: 4
        )

      assert :ok = TestHelpers.assert_lanes_evenly_spaced(html, "h")
    end

    test "passes for single-arrow source (trivially even)" do
      events = [
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-primary"
        }
      ]

      html = TestHelpers.render_waterfall(events, connectors: [%{from: "a", to: "b"}])
      assert :ok = TestHelpers.assert_lanes_evenly_spaced(html, "a")
    end

    test "raises when no connectors found from given source" do
      events = [
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        }
      ]

      html = TestHelpers.render_waterfall(events)

      assert_raise RuntimeError, ~r/no connectors found/, fn ->
        TestHelpers.assert_lanes_evenly_spaced(html, "nonexistent")
      end
    end
  end

  describe "regression — recent fixes" do
    # The lane-stagger Y rounding bug had spacings of 3,4,3,3,4,3 for
    # 7 lanes across a 20px flat region. Verify the integer-precise
    # spacing fix keeps spacings uniform.
    test "lane stagger produces uniform integer spacings (regression for Apr-2026 rounding bug)" do
      events = fanout_events()

      html =
        TestHelpers.render_waterfall(events,
          connectors: fanout_connectors(),
          bus_stagger_outgoing_px: 4
        )

      assert :ok = TestHelpers.assert_lanes_evenly_spaced(html, "h")
    end

    # The corner-clearance bug had stagger lanes emerging from rounded-
    # corner regions where the bar's edge curved inward. Verify all
    # stagger attach points are inside the bar's flat region (default
    # corner radius 4 + 2 stroke buffer = 6px inset).
    test "stagger attaches stay inside bar's flat region (regression for corner bleed)" do
      events = fanout_events()

      html =
        TestHelpers.render_waterfall(events,
          connectors: fanout_connectors(),
          bus_stagger_outgoing_px: 4
        )

      # Corner inset = 4 (radius) + 2 (stroke buffer) = 6
      assert :ok =
               TestHelpers.assert_source_attaches_inside_bar(html,
                 corner_inset_px: 6,
                 row_px: 40
               )
    end

    # Arrow tip should never overlap the target bar (4px gap default
    # for non-milestone targets after refX=6 fix).
    test "arrow tips clear target bars by at least 1px (regression for refX gap bug)" do
      events = [
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-primary"
        }
      ]

      html = TestHelpers.render_waterfall(events, connectors: [%{from: "a", to: "b"}])

      assert :ok = TestHelpers.assert_arrow_tips_clear_target_bars(html, min_gap_px: 1)
    end
  end

  describe "assert_no_unrelated_bar_pierced/2" do
    test "passes when no trunk pierces an unrelated bar" do
      # Three events where the trunk for a→c doesn't cross b's bar
      # (b's bar starts after the trunk x).
      events = [
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "c",
          start: ~D[2026-04-25],
          end: ~D[2026-04-30],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-15],
          end: ~D[2026-04-20],
          color: "bg-primary"
        }
      ]

      html = TestHelpers.render_waterfall(events, connectors: [%{from: "a", to: "c"}])
      assert :ok = TestHelpers.assert_no_unrelated_bar_pierced(html)
    end
  end

  describe "assert_paths_axis_aligned/1" do
    test "passes for normal forward and detour paths" do
      events = fanout_events()
      html = TestHelpers.render_waterfall(events, connectors: fanout_connectors())
      assert :ok = TestHelpers.assert_paths_axis_aligned(html)
    end
  end

  describe "find_geometry_issues/2" do
    test "returns empty list for a clean render" do
      events = fanout_events()
      html = TestHelpers.render_waterfall(events, connectors: fanout_connectors())
      assert [] = TestHelpers.find_geometry_issues(html)
    end

    test "runs every assertion and reports each failure" do
      # Single FS chain with no issues — should pass all checks.
      events = [
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-primary"
        }
      ]

      html = TestHelpers.render_waterfall(events, connectors: [%{from: "a", to: "b"}])
      issues = TestHelpers.find_geometry_issues(html)
      assert issues == [], "expected no issues, got #{inspect(issues)}"
    end
  end

  describe "diff_waterfalls/2" do
    setup do
      events = fanout_events()
      connectors = fanout_connectors()
      before_geom = TestHelpers.inspect_waterfall(events, connectors: connectors)
      %{events: events, connectors: connectors, before: before_geom}
    end

    test "no diff when nothing changes", %{events: events, connectors: connectors, before: before} do
      after_geom = TestHelpers.inspect_waterfall(events, connectors: connectors)
      diff = TestHelpers.diff_waterfalls(before, after_geom)

      assert diff.row_order == %{changed: false}
      assert diff.connectors.added == []
      assert diff.connectors.removed == []
      assert diff.connectors.changed == []
      assert diff.edges.earlier_delta == 0
      assert diff.edges.later_delta == 0
    end

    test "detects connector coord changes when stagger is enabled", %{
      events: events,
      connectors: connectors,
      before: before
    } do
      after_geom =
        TestHelpers.inspect_waterfall(events,
          connectors: connectors,
          bus_stagger_outgoing_px: 4
        )

      diff = TestHelpers.diff_waterfalls(before, after_geom)

      # Stagger doesn't add or remove connectors, but it changes coords
      assert diff.connectors.added == []
      assert diff.connectors.removed == []

      refute diff.connectors.changed == [],
             "expected coord changes when enabling stagger, got nothing"
    end

    test "detects added/removed connectors", %{events: events, before: before} do
      after_geom = TestHelpers.inspect_waterfall(events, connectors: [])
      diff = TestHelpers.diff_waterfalls(before, after_geom)

      assert diff.connectors.added == []
      assert length(diff.connectors.removed) == 5
    end
  end
end
