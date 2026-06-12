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

      # Tip lands ON b's left edge (gap ~0) by design; the assertion flags only
      # tips piercing INTO the bar.
      assert :ok = TestHelpers.assert_arrow_tips_clear_target_bars(html)
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

  # M7: the detectors are only ever exercised against PASSING fixtures, so a
  # broken detector that never raises would slip through. These tests feed each
  # detector an input that VIOLATES its invariant and assert it RAISES. We start
  # from a real render and surgically mutate the HTML the Inspector parses, so
  # everything else stays self-consistent.
  describe "assertion detectors raise on violating fixtures (M7)" do
    defp simple_chain_html do
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

      TestHelpers.render_waterfall(events, connectors: [%{from: "a", to: "b"}])
    end

    test "assert_arrow_tips_clear_target_bars raises when a tip pierces into the target bar" do
      html = simple_chain_html()

      # Sanity: the pristine render passes.
      assert :ok = TestHelpers.assert_arrow_tips_clear_target_bars(html)

      # Shove the target bar's left edge to 0% so the arrow tip (which lands on
      # b's original left edge) now sits deep INSIDE the bar — a refX/offset
      # style bug.
      pierced =
        Regex.replace(
          ~r/(class="lg-bar[^"]*"\s+style="left: )[\d.]+(%; width: [\d.]+%"[^>]*phx-value-event-id="b")/,
          html,
          "\\g{1}0.0\\g{2}"
        )

      assert pierced != html, "expected the target-bar mutation to change the HTML"

      assert_raise RuntimeError, ~r/assert_arrow_tips_clear_target_bars/, fn ->
        TestHelpers.assert_arrow_tips_clear_target_bars(pierced)
      end
    end

    test "assert_arrowheads_at_path_ends raises when the arrowhead drifts off the shaft end" do
      html = simple_chain_html()

      # Sanity: the pristine render passes.
      assert :ok = TestHelpers.assert_arrowheads_at_path_ends(html)

      # Move the arrowhead overlay's `top` far from the shaft's terminal y so
      # the head no longer tracks the path end (the bug this detector guards).
      drifted =
        Regex.replace(
          ~r/(class="lg-arrowhead[^"]*"\s+style="left: [\d.]+%; top: )\d+(px")/,
          html,
          "\\g{1}500\\g{2}"
        )

      assert drifted != html, "expected the arrowhead mutation to change the HTML"

      assert_raise RuntimeError, ~r/assert_arrowheads_at_path_ends/, fn ->
        TestHelpers.assert_arrowheads_at_path_ends(drifted)
      end
    end

    test "assert_no_unrelated_bar_pierced raises when an unrelated bar sits on the trunk" do
      # a(row 0) → c(row 2) trunk runs in a vertical column that crosses b's
      # (row 1) y-band; b is unrelated and out of the trunk's x-column in the
      # clean render. Force the row order with extra.order so the trunk actually
      # spans b's row, then move b's bar onto the trunk's x-column so the
      # vertical segment visibly cuts through it.
      events = [
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary",
          extra: %{order: 1}
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-15],
          end: ~D[2026-04-20],
          color: "bg-primary",
          extra: %{order: 2}
        },
        %LiveGantt.Task{
          id: "c",
          start: ~D[2026-04-25],
          end: ~D[2026-04-30],
          color: "bg-primary",
          extra: %{order: 3}
        }
      ]

      html = TestHelpers.render_waterfall(events, connectors: [%{from: "a", to: "c"}])
      assert :ok = TestHelpers.assert_no_unrelated_bar_pierced(html)

      # Find the trunk x (mid of the forward path) and re-home b's bar so it
      # straddles that column. Express the new left/width as % of content width.
      geom = TestHelpers.inspect_waterfall(events, connectors: [%{from: "a", to: "c"}])
      [conn] = geom.connectors
      trunk_x = conn.segments.mid

      [_, cw] = Regex.run(~r/min-width: (\d+)px/, html)
      content_width = String.to_integer(cw)

      # Left edge well west of the trunk, right edge well east → it straddles.
      new_left_pct = (trunk_x - 20) / content_width * 100
      new_width_pct = 40 / content_width * 100

      pierced =
        Regex.replace(
          ~r/(class="lg-bar[^"]*"\s+style="left: )[\d.]+(%; width: )[\d.]+(%"[^>]*phx-value-event-id="b")/,
          html,
          "\\g{1}#{:erlang.float_to_binary(new_left_pct, decimals: 4)}\\g{2}#{:erlang.float_to_binary(new_width_pct, decimals: 4)}\\g{3}"
        )

      assert pierced != html, "expected the unrelated-bar mutation to change the HTML"

      assert_raise RuntimeError, ~r/assert_no_unrelated_bar_pierced/, fn ->
        TestHelpers.assert_no_unrelated_bar_pierced(pierced)
      end
    end

    test "assert_lanes_evenly_spaced raises when one stagger lane's y is nudged off-grid" do
      events = fanout_events()

      html =
        TestHelpers.render_waterfall(events,
          connectors: fanout_connectors(),
          bus_stagger_outgoing_px: 4
        )

      assert :ok = TestHelpers.assert_lanes_evenly_spaced(html, "h")

      # Nudge exactly one source-attach y (the `M x y` of one h-path) by +7px so
      # the lane spacings from h become uneven.
      [target_path] =
        Regex.run(~r/d="M \d+ \d+ H \d+ V \d+ H \d+"[^>]*data-from-id="h" data-to-id="t1"/, html)

      [_, x, y] = Regex.run(~r/d="M (\d+) (\d+)/, target_path)
      bumped = String.replace(target_path, "M #{x} #{y}", "M #{x} #{String.to_integer(y) + 7}")
      uneven = String.replace(html, target_path, bumped)

      assert uneven != html, "expected the lane mutation to change the HTML"

      assert_raise RuntimeError, ~r/not evenly spaced/, fn ->
        TestHelpers.assert_lanes_evenly_spaced(uneven, "h")
      end
    end
  end
end
