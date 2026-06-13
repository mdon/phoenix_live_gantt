defmodule LiveGanttTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import ExUnit.CaptureIO, only: [capture_io: 1]
  import LiveGantt

  alias Mix.Tasks.LiveGantt.Dump

  defp render(content), do: rendered_to_string(content)

  defp sample_events(base \\ ~D[2026-04-01]) do
    [
      %LiveGantt.Task{
        id: "t1",
        start: base,
        end: Date.add(base, 5),
        title: "Task One",
        color: "bg-primary",
        category: "Phase 1",
        extra: %{progress_pct: 80, assignee: "Alice", group: "Phase 1"}
      },
      %LiveGantt.Task{
        id: "t2",
        start: Date.add(base, 5),
        end: Date.add(base, 12),
        title: "Task Two",
        color: "bg-accent",
        category: "Phase 1",
        extra: %{progress_pct: 30, group: "Phase 1"}
      },
      %LiveGantt.Task{
        id: "t3",
        start: Date.add(base, 12),
        end: Date.add(base, 20),
        title: "Task Three",
        color: "bg-secondary",
        category: "Phase 2",
        extra: %{progress_pct: 0, group: "Phase 2"}
      }
    ]
  end

  defp sample_range, do: Date.range(~D[2026-04-01], ~D[2026-05-30])

  describe "waterfall/1" do
    test "renders waterfall structure" do
      assigns = %{events: sample_events(), range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      assert html =~ "lg"
      assert html =~ "lg-header"
      assert html =~ "lg-label"
      assert html =~ "lg-bar"
    end

    test "renders event titles in labels" do
      assigns = %{events: sample_events(), range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      assert html =~ "Task One"
      assert html =~ "Task Two"
      assert html =~ "Task Three"
    end

    test "renders group headers" do
      assigns = %{events: sample_events(), range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      assert html =~ "lg-group"
      assert html =~ "Phase 1"
      assert html =~ "Phase 2"
    end

    test "renders progress fill" do
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-10],
          title: "With Progress",
          color: "bg-primary",
          extra: %{progress_pct: 60}
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      assert html =~ "width: 60%"
    end

    test "reads progress_pct + assignee from struct fields (not just extra)" do
      # The README quickstart sets these as struct fields; the renderer must read
      # them struct-first (with extra.* as the fallback).
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-10],
          title: "Struct fields",
          color: "bg-primary",
          progress_pct: 60,
          assignee: "Sara"
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      assert html =~ "width: 60%"
      assert html =~ "Sara"
    end

    test "renders milestones for zero-duration events" do
      events = [
        %LiveGantt.Task{
          id: "m1",
          start: ~D[2026-04-15],
          end: ~D[2026-04-15],
          title: "Milestone",
          color: "bg-success",
          icon: "◆"
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      assert html =~ "lg-milestone"
    end

    test "renders today marker" do
      today = ~D[2026-04-15]
      events = sample_events()
      assigns = %{events: events, range: sample_range(), today: today}

      html = render(~H"<.gantt events={@events} date_range={@range} today={@today} />")

      assert html =~ "bg-error"
      assert html =~ "Today"
    end

    test "hides today marker when outside range" do
      today = ~D[2027-01-01]
      assigns = %{events: sample_events(), range: sample_range(), today: today}

      html = render(~H"<.gantt events={@events} date_range={@range} today={@today} />")

      # Should not have the today line (it renders bg-error for the line)
      refute html =~ "w-0.5 bg-error"
    end

    test "a Date today clamps onto a sub-day afternoon window (N5)" do
      # A bare Date today (noon-anchored) overlaps an afternoon sub-day window, so
      # the whole-day overlap test shows the marker (no off-screen pill). But noon
      # (12:00) sits LEFT of a 13:00–18:00 window, so the un-clamped marker would
      # draw at a negative left% — off-screen with nothing to see. It must pin to
      # the window's near (left) edge instead.
      events = [
        %LiveGantt.Task{
          id: "t",
          title: "T",
          start: ~N[2026-04-01 14:00:00],
          end: ~N[2026-04-01 16:00:00]
        }
      ]

      assigns = %{
        events: events,
        range: Date.range(~D[2026-04-01], ~D[2026-04-01]),
        today: ~D[2026-04-01],
        ws: ~N[2026-04-01 13:00:00],
        we: ~N[2026-04-01 18:00:00]
      }

      html =
        render(~H[<.gantt
  id="w"
  events={@events}
  date_range={@range}
  today={@today}
  zoom={:hour}
  window_start={@ws}
  window_end={@we}
/>])

      assert html =~ "lg-today", "today marker should render for an overlapping day"
      [_, left] = Regex.run(~r/lg-today[^>]*left:\s*([\d.-]+)%/, html)
      assert String.to_float(left) >= 0.0, "today marker clamped off-screen at left: #{left}%"
    end

    test "renders with day zoom" do
      range = Date.range(~D[2026-04-01], ~D[2026-04-14])

      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-07],
          title: "Week Task",
          color: "bg-primary"
        }
      ]

      assigns = %{events: events, range: range}

      html = render(~H"<.gantt events={@events} date_range={@range} zoom={:day} />")

      assert html =~ "lg"
      # Day zoom shows individual day numbers in column headers
      assert html =~ "40px"
      assert html =~ ~r/>\s*1\s*</
      assert html =~ ~r/>\s*14\s*</
    end

    test "renders with month zoom" do
      range = Date.range(~D[2026-04-01], ~D[2026-09-30])

      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-06-30],
          title: "Long Project",
          color: "bg-primary"
        }
      ]

      assigns = %{events: events, range: range}

      html = render(~H"<.gantt events={@events} date_range={@range} zoom={:month} />")

      assert html =~ "lg"
      assert html =~ "Apr"
      assert html =~ "Sep"
    end

    test "renders connector lines" do
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "First",
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-05],
          end: ~D[2026-04-10],
          title: "Second",
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "t1", to: "t2"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ "lg-connectors"
      assert html =~ "lg-arrow"
      assert html =~ "<path"
    end

    test "styles backward (invalid) connectors differently" do
      # Target starts BEFORE source ends — an impossible/broken dependency
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-15],
          end: ~D[2026-04-25],
          title: "Source",
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-05],
          end: ~D[2026-04-10],
          title: "Before Source",
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "t1", to: "t2"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ "text-error"
      assert html =~ "stroke-dasharray=\"4 3\""
      assert html =~ "lg-arrow-invalid"
    end

    test "uses normal style for forward connectors with gaps" do
      # Gap between source end and target start (e.g., vacation) — normal forward dep
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "Source",
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-20],
          end: ~D[2026-04-25],
          title: "Delayed",
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "t1", to: "t2"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ "text-base-content/50"
      refute html =~ ~s(data-invalid="true")
    end

    test "renders without connectors when empty" do
      assigns = %{events: sample_events(), range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      refute html =~ "lg-connectors"
    end

    test "renders event with cancelled status" do
      events = [
        %LiveGantt.Task{
          id: "c1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-10],
          title: "Cancelled Task",
          color: "bg-error",
          status: :cancelled
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      assert html =~ "line-through"
      assert html =~ "opacity-40"
    end

    test "renders assignee in label" do
      events = [
        %LiveGantt.Task{
          id: "a1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "Assigned Task",
          color: "bg-primary",
          extra: %{assignee: "Bob"}
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      assert html =~ "Bob"
    end

    test "reorders events so direct dependents are adjacent to their sources" do
      # Events sorted by start date alone would be: A, B, C, D (where C depends on A).
      # The reorder should place C right after A to minimize arrow crossings:
      # A, C, B, D.
      events = [
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "A",
          color: "bg-primary",
          category: "Phase"
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-02],
          end: ~D[2026-04-06],
          title: "B (parallel)",
          color: "bg-accent",
          category: "Phase"
        },
        %LiveGantt.Task{
          id: "c",
          start: ~D[2026-04-03],
          end: ~D[2026-04-08],
          title: "C depends on A",
          color: "bg-secondary",
          category: "Phase"
        },
        %LiveGantt.Task{
          id: "d",
          start: ~D[2026-04-10],
          end: ~D[2026-04-14],
          title: "D",
          color: "bg-info",
          category: "Phase"
        }
      ]

      connectors = [%{from: "a", to: "c"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # Find positions in the output — "C depends on A" should appear before "B (parallel)"
      a_pos = :binary.match(html, "A") |> elem(0)
      b_pos = :binary.match(html, "B (parallel)") |> elem(0)
      c_pos = :binary.match(html, "C depends on A") |> elem(0)

      assert a_pos < c_pos, "A should appear before C"
      assert c_pos < b_pos, "C should appear before B (placed adjacent to source A)"
    end

    test "smart mode splits attach y by direction and incoming/outgoing class" do
      # Hub task 'h' has 1 outgoing :fs (target 'out' is BELOW h) AND 1
      # incoming :ff (source 'in' is ABOVE h). Both connectors touch h's
      # east edge.
      #
      # Smart-mode expectations:
      #   - h's outgoing arrow → :out_down → attaches near the BOTTOM of h's bar
      #   - h's incoming arrow → :in_above → attaches in the UPPER region of h's bar
      # So incoming y should be SMALLER (higher up) than outgoing y.
      events = [
        %LiveGantt.Task{
          id: "in",
          start: ~D[2026-04-05],
          end: ~D[2026-04-15],
          color: "bg-secondary"
        },
        %LiveGantt.Task{
          id: "h",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "out",
          start: ~D[2026-04-16],
          end: ~D[2026-04-20],
          color: "bg-accent"
        }
      ]

      connectors = [
        %{from: "h", to: "out", type: :fs},
        %{from: "in", to: "h", type: :ff}
      ]

      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"""
        <.gantt events={@events} date_range={@range} connectors={@connectors} />
        """)

      # Path shape: "M x1 y1 H mid V y2 H arrow_stop". Capture y1 and y2.
      paths =
        Regex.scan(
          ~r/d="M \d+ (\d+) H \d+ V (\d+) H \d+"[^>]*data-from-id="([^"]+)" data-to-id="([^"]+)"/,
          html
        )

      h_outgoing = Enum.find(paths, fn [_, _, _, from, _to] -> from == "h" end)
      h_incoming = Enum.find(paths, fn [_, _, _, _from, to] -> to == "h" end)

      assert h_outgoing, "outgoing arrow from h not found"
      assert h_incoming, "incoming arrow to h not found"

      # h's source-side y is y1 of h_outgoing (h is source).
      # h's target-side y is y2 of h_incoming (h is target).
      [_, h_out_y, _, _, _] = h_outgoing
      [_, _, h_in_y, _, _] = h_incoming

      h_out_y_int = String.to_integer(h_out_y)
      h_in_y_int = String.to_integer(h_in_y)

      # row order after auto-place: in=0, h=1, out=2. h's row top=40,
      # bar_top=44, bar_height=32. Defaults: outer=20%, inner=40%.
      # h_out (out_down): 44 + 32*0.8 = 69 (≈ row 1's bottom region)
      # h_in (in_above):  44 + 32*0.4 = 56 (≈ row 1's upper region)
      assert h_in_y_int < h_out_y_int,
             "in_above attach (#{h_in_y_int}) should be ABOVE out_down attach (#{h_out_y_int})"

      assert h_out_y_int - h_in_y_int >= 8,
             "split should be at least 8px (got #{h_out_y_int - h_in_y_int})"
    end

    test "smart mode collapses to bar center when only one attach class is present" do
      # Single outgoing FS — only :out_down on source's east side, only
      # :in_above on target's west side. Each side has just one class →
      # both ends should attach at row center (no split).
      events = [
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-08],
          end: ~D[2026-04-12],
          color: "bg-primary"
        }
      ]

      connectors = [%{from: "a", to: "b", type: :fs}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"""
        <.gantt events={@events} date_range={@range} connectors={@connectors} />
        """)

      [[_, _x1, y1, _mid, y2, _stop]] =
        Regex.scan(~r/d="M (\d+) (\d+) H (\d+) V (\d+) H (\d+)"[^>]*data-from-id/, html)

      # row 0 center = 20, row 1 center = 60 (40px row, no group header)
      assert y1 == "20", "single-class side should center y1 (got #{y1})"
      assert y2 == "60", "single-class side should center y2 (got #{y2})"
    end

    test "type_zoned mode keeps legacy outgoing-top / incoming-bottom split" do
      # Same hub setup as the smart-mode test, but pass bus_attach_mode={:type_zoned}.
      # Expected: outgoing always at TOP region of bar regardless of direction.
      events = [
        %LiveGantt.Task{
          id: "in",
          start: ~D[2026-04-05],
          end: ~D[2026-04-15],
          color: "bg-secondary"
        },
        %LiveGantt.Task{
          id: "h",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "out",
          start: ~D[2026-04-16],
          end: ~D[2026-04-20],
          color: "bg-accent"
        }
      ]

      connectors = [
        %{from: "h", to: "out", type: :fs},
        %{from: "in", to: "h", type: :ff}
      ]

      assigns = %{
        events: events,
        range: sample_range(),
        connectors: connectors,
        mode: :type_zoned
      }

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          connectors={@connectors}
          bus_attach_mode={@mode}
        />
        """)

      paths =
        Regex.scan(
          ~r/d="M \d+ (\d+) H \d+ V (\d+) H \d+"[^>]*data-from-id="([^"]+)" data-to-id="([^"]+)"/,
          html
        )

      h_outgoing = Enum.find(paths, fn [_, _, _, from, _to] -> from == "h" end)
      h_incoming = Enum.find(paths, fn [_, _, _, _from, to] -> to == "h" end)

      [_, h_out_y, _, _, _] = h_outgoing
      [_, _, h_in_y, _, _] = h_incoming

      h_out_y_int = String.to_integer(h_out_y)
      h_in_y_int = String.to_integer(h_in_y)

      # type_zoned: outgoing at top region (smaller y), incoming at bottom.
      assert h_out_y_int < h_in_y_int,
             "type_zoned: outgoing (#{h_out_y_int}) must be ABOVE incoming (#{h_in_y_int})"
    end

    test "center mode disables splits entirely" do
      events = [
        %LiveGantt.Task{
          id: "in",
          start: ~D[2026-04-05],
          end: ~D[2026-04-15],
          color: "bg-secondary"
        },
        %LiveGantt.Task{
          id: "h",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "out",
          start: ~D[2026-04-16],
          end: ~D[2026-04-20],
          color: "bg-accent"
        }
      ]

      connectors = [
        %{from: "h", to: "out", type: :fs},
        %{from: "in", to: "h", type: :ff}
      ]

      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          connectors={@connectors}
          bus_attach_mode={:center}
        />
        """)

      paths =
        Regex.scan(
          ~r/d="M \d+ (\d+) H \d+ V (\d+) H \d+"[^>]*data-from-id="([^"]+)" data-to-id="([^"]+)"/,
          html
        )

      h_outgoing = Enum.find(paths, fn [_, _, _, from, _to] -> from == "h" end)
      [_, h_out_y, _, _, _] = h_outgoing

      # h is at row 1 (in=0, h=1, out=2). row 1 center y = 60.
      assert h_out_y == "60", "center mode: should attach at row center 60 (got #{h_out_y})"
    end

    test "bus_stagger_outgoing_px spreads fan-out arrows into separate trunks" do
      # Hub 'h' has 3 outgoing :fs arrows. With stagger=4, each arrow lands
      # on its own trunk x. Lane order is by target row position; lanes 0,1,2
      # get +0, +4, +8 px (east, since :fs source exit is east).
      events = [
        %LiveGantt.Task{
          id: "h",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-08],
          end: ~D[2026-04-10],
          color: "bg-accent"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-08],
          end: ~D[2026-04-10],
          color: "bg-accent"
        },
        %LiveGantt.Task{
          id: "t3",
          start: ~D[2026-04-08],
          end: ~D[2026-04-10],
          color: "bg-accent"
        }
      ]

      connectors = [
        %{from: "h", to: "t1", type: :fs},
        %{from: "h", to: "t2", type: :fs},
        %{from: "h", to: "t3", type: :fs}
      ]

      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          connectors={@connectors}
          bus_stagger_outgoing_px={4}
        />
        """)

      mids =
        Regex.scan(
          ~r/d="M \d+ \d+ H (\d+) V \d+ H \d+"[^>]*data-from-id="h"/,
          html
        )
        |> Enum.map(fn [_, mid] -> String.to_integer(mid) end)
        |> Enum.uniq()
        |> Enum.sort()

      assert length(mids) == 3,
             "expected 3 distinct trunk x values, got #{inspect(mids)}"

      [a, b, c] = mids

      assert b - a == 4 and c - b == 4,
             "expected 4px stagger between lanes, got #{b - a} / #{c - b}"
    end

    test "bus_stagger_outgoing_px=0 (default) merges fan-out arrows into one trunk" do
      events = [
        %LiveGantt.Task{
          id: "h",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-08],
          end: ~D[2026-04-10],
          color: "bg-accent"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-08],
          end: ~D[2026-04-10],
          color: "bg-accent"
        }
      ]

      connectors = [
        %{from: "h", to: "t1", type: :fs},
        %{from: "h", to: "t2", type: :fs}
      ]

      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"""
        <.gantt events={@events} date_range={@range} connectors={@connectors} />
        """)

      mids =
        Regex.scan(
          ~r/d="M \d+ \d+ H (\d+) V \d+ H \d+"[^>]*data-from-id="h"/,
          html
        )
        |> Enum.map(fn [_, mid] -> String.to_integer(mid) end)
        |> Enum.uniq()

      assert length(mids) == 1,
             "default stagger=0 should merge to one trunk; got #{inspect(mids)}"
    end

    test "extra.bus_stagger_outgoing_px on a task overrides the component setting" do
      # Component default = 5 (would normally stagger), but h has
      # extra.bus_stagger_outgoing_px = 0 → h's outgoing arrows merge.
      events = [
        %LiveGantt.Task{
          id: "h",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary",
          extra: %{bus_stagger_outgoing_px: 0}
        },
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-08],
          end: ~D[2026-04-10],
          color: "bg-accent"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-08],
          end: ~D[2026-04-10],
          color: "bg-accent"
        }
      ]

      connectors = [
        %{from: "h", to: "t1", type: :fs},
        %{from: "h", to: "t2", type: :fs}
      ]

      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          connectors={@connectors}
          bus_stagger_outgoing_px={5}
        />
        """)

      mids =
        Regex.scan(
          ~r/d="M \d+ \d+ H (\d+) V \d+ H \d+"[^>]*data-from-id="h"/,
          html
        )
        |> Enum.map(fn [_, mid] -> String.to_integer(mid) end)
        |> Enum.uniq()

      assert length(mids) == 1,
             "per-task override should merge h's outgoing; got #{inspect(mids)}"
    end

    test "extra.bus_attach_mode on a task overrides the component mode" do
      # Component default is :smart, but h has extra.bus_attach_mode={:center}
      # so h's attachments should be centered while other tasks aren't affected.
      events = [
        %LiveGantt.Task{
          id: "in",
          start: ~D[2026-04-05],
          end: ~D[2026-04-15],
          color: "bg-secondary"
        },
        %LiveGantt.Task{
          id: "h",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-primary",
          extra: %{bus_attach_mode: :center}
        },
        %LiveGantt.Task{
          id: "out",
          start: ~D[2026-04-16],
          end: ~D[2026-04-20],
          color: "bg-accent"
        }
      ]

      connectors = [
        %{from: "h", to: "out", type: :fs},
        %{from: "in", to: "h", type: :ff}
      ]

      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"""
        <.gantt events={@events} date_range={@range} connectors={@connectors} />
        """)

      paths =
        Regex.scan(
          ~r/d="M \d+ (\d+) H \d+ V (\d+) H \d+"[^>]*data-from-id="([^"]+)" data-to-id="([^"]+)"/,
          html
        )

      h_outgoing = Enum.find(paths, fn [_, _, _, from, _to] -> from == "h" end)
      [_, h_out_y, _, _, _] = h_outgoing

      assert h_out_y == "60",
             "h with :center override should attach at row center 60 (got #{h_out_y})"
    end

    test "uses bar center when a side has only one direction" do
      # Standard FS chain: each task has at most one outgoing and one incoming
      # on different sides (outgoing east, incoming west). No same-side mix.
      # Attachment should stay at row center (~row.top + 20).
      events = [
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-08],
          end: ~D[2026-04-12],
          color: "bg-primary"
        }
      ]

      connectors = [%{from: "a", to: "b", type: :fs}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"""
        <.gantt events={@events} date_range={@range} connectors={@connectors} />
        """)

      # Filter to actual connector paths (carry data-from-id), not the
      # SVG marker defs which also start with M.
      # Path shape: "M x1 y1 H mid V y2 H arrow_stop"
      [[_, _x1, y1, _mid, y2, _stop]] =
        Regex.scan(~r/d="M (\d+) (\d+) H (\d+) V (\d+) H (\d+)"[^>]*data-from-id/, html)

      # row 0 center = 20, row 1 center = 60 (40px row, no group header)
      assert y1 == "20", "expected y1 = row 0 center (20), got #{y1}"
      assert y2 == "60", "expected y2 = row 1 center (60), got #{y2}"
    end

    test "sorts events chronologically across month boundaries" do
      # Regression: Date structs default-compare by :day key alphabetically,
      # so without the `Date` sorter, July 5 sorts BEFORE May 14 (5 < 14).
      # auto_place_group must use Date.compare semantics for dates that
      # cross month boundaries with day-of-month < the smaller-month dates.
      events = [
        %LiveGantt.Task{
          id: "may",
          start: ~D[2026-05-14],
          end: ~D[2026-05-20],
          title: "May task",
          category: "Phase"
        },
        %LiveGantt.Task{
          id: "july",
          start: ~D[2026-07-05],
          end: ~D[2026-07-10],
          title: "July task",
          category: "Phase"
        }
      ]

      range = Date.range(~D[2026-05-01], ~D[2026-08-30])
      assigns = %{events: events, range: range}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      may_pos = :binary.match(html, "May task") |> elem(0)
      july_pos = :binary.match(html, "July task") |> elem(0)

      assert may_pos < july_pos,
             "May task (2026-05-14) must render before July task (2026-07-05)"
    end

    test "places critical-path dependents before parallel branches with earlier starts" do
      # A has two dependents: C (critical) and B (parallel, earlier start).
      # Without critical-first sorting, B would be placed adjacent to A
      # because it starts sooner. With critical-first sorting, C wins so
      # the critical chain stays on adjacent rows.
      events = [
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "A source",
          category: "Phase"
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-03],
          end: ~D[2026-04-08],
          title: "B parallel",
          category: "Phase"
        },
        %LiveGantt.Task{
          id: "c",
          start: ~D[2026-04-05],
          end: ~D[2026-04-12],
          title: "C critical",
          category: "Phase"
        }
      ]

      connectors = [
        %{from: "a", to: "c", critical: true},
        %{from: "a", to: "b"}
      ]

      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      a_pos = :binary.match(html, "A source") |> elem(0)
      b_pos = :binary.match(html, "B parallel") |> elem(0)
      c_pos = :binary.match(html, "C critical") |> elem(0)

      assert a_pos < c_pos, "A should come before C"

      assert c_pos < b_pos,
             "C (critical) should come before B (non-critical) despite B's earlier start"
    end

    test "respects explicit extra.order override" do
      events = [
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "First by date",
          color: "bg-primary",
          category: "Phase",
          extra: %{order: 2}
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-05],
          end: ~D[2026-04-10],
          title: "Second by date",
          color: "bg-accent",
          category: "Phase",
          extra: %{order: 1}
        }
      ]

      assigns = %{events: events, range: sample_range()}
      html = render(~H"<.gantt events={@events} date_range={@range} />")

      # With explicit order, B (order: 1) comes before A (order: 2)
      b_pos = :binary.match(html, "Second by date") |> elem(0)
      a_pos = :binary.match(html, "First by date") |> elem(0)

      assert b_pos < a_pos, "Event with order=1 should appear before order=2"
    end

    test "renders empty waterfall" do
      assigns = %{range: sample_range()}

      html = render(~H"<.gantt events={[]} date_range={@range} />")

      assert html =~ "lg"
      assert html =~ "lg-header"
      # No bars or labels rendered (look for the actual element class
      # on a DOM node — string occurrences in <style> blocks don't count).
      refute html =~ ~r/<div[^>]*class="lg-bar /
      refute html =~ "lg-label flex"
    end

    test "hides events entirely outside the visible date range" do
      # Visible range: April only. One event inside, two entirely outside.
      events = [
        %LiveGantt.Task{
          id: "in",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          title: "Inside"
        },
        %LiveGantt.Task{
          id: "before",
          start: ~D[2026-02-01],
          end: ~D[2026-02-10],
          title: "Way Before"
        },
        %LiveGantt.Task{
          id: "after",
          start: ~D[2026-06-01],
          end: ~D[2026-06-10],
          title: "Way After"
        }
      ]

      range = Date.range(~D[2026-04-01], ~D[2026-04-30])
      assigns = %{events: events, range: range}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      # Inside event is rendered
      assert html =~ "Inside"
      # Out-of-range events have no row and no bar (they're filtered upstream)
      refute html =~ "Way Before"
      refute html =~ "Way After"
    end

    test "partially-overlapping events clip but still render" do
      # Event starts before range, ends inside → should render as a clipped bar
      events = [
        %LiveGantt.Task{
          id: "clip",
          start: ~D[2026-03-25],
          end: ~D[2026-04-10],
          title: "Clipped"
        }
      ]

      range = Date.range(~D[2026-04-01], ~D[2026-04-30])
      assigns = %{events: events, range: range}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      assert html =~ "Clipped"
      assert html =~ "lg-bar"
    end

    test "shows edge indicators with out-of-range counts" do
      events = [
        %LiveGantt.Task{
          id: "in",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          title: "Inside"
        },
        %LiveGantt.Task{id: "b1", start: ~D[2026-02-01], end: ~D[2026-02-05], title: "B1"},
        %LiveGantt.Task{id: "b2", start: ~D[2026-02-20], end: ~D[2026-02-25], title: "B2"},
        %LiveGantt.Task{id: "a1", start: ~D[2026-05-01], end: ~D[2026-05-05], title: "A1"}
      ]

      range = Date.range(~D[2026-04-01], ~D[2026-04-30])
      assigns = %{events: events, range: range}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      # 2 earlier events, 1 later event should appear as pills
      assert html =~ "lg-edge-earlier"
      assert html =~ "2 earlier"
      assert html =~ "lg-edge-later"
      assert html =~ "1 later"
    end

    test "skips connectors touching out-of-range events" do
      events = [
        %LiveGantt.Task{
          id: "in",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          title: "Inside"
        },
        %LiveGantt.Task{
          id: "out",
          start: ~D[2026-06-01],
          end: ~D[2026-06-10],
          title: "Outside"
        }
      ]

      connectors = [%{from: "in", to: "out"}]
      range = Date.range(~D[2026-04-01], ~D[2026-04-30])
      assigns = %{events: events, connectors: connectors, range: range}

      html =
        render(~H"""
        <.gantt events={@events} connectors={@connectors} date_range={@range} />
        """)

      # Connector is dropped because one endpoint is out of range
      refute html =~ ~s(data-from-id="in" data-to-id="out")
    end

    test "renders built-in toolbar when show_header is true" do
      assigns = %{events: sample_events(), range: sample_range()}

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          show_header={true}
          on_zoom_change="wf_zoom_change"
          on_navigate="wf_navigate"
        />
        """)

      assert html =~ "lg-toolbar"
      assert html =~ "lg-zoom"
      assert html =~ "lg-today-btn"
      assert html =~ "lg-nav-prev"
      assert html =~ "lg-nav-next"
    end

    test "omits toolbar when show_header is false (default)" do
      assigns = %{events: sample_events(), range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      refute html =~ "lg-toolbar"
    end

    test "hour zoom positions bars at sub-day precision from DateTime starts" do
      # 09:00–11:00 (2h) on day 0 of a 2-day range. At hour zoom day_px = 720
      # (30px/hour): left = 0.375*720 = 270, width = 2h = 60px.
      events = [
        %LiveGantt.Task{
          id: "t",
          title: "Two hours",
          start: ~N[2026-04-01 09:00:00],
          end: ~N[2026-04-01 11:00:00]
        }
      ]

      assigns = %{events: events, range: Date.range(~D[2026-04-01], ~D[2026-04-02])}

      html = render(~H[<.gantt id="h" events={@events} date_range={@range} zoom={:hour} />])

      # Horizontal coords render as % of content width. content width is
      # 2d × 720 + 2 × @axis_pad_px (16) = 1472px; bar x is also shifted by the
      # pad: left (16 + 270)/1472 = 19.4293%, width 60/1472 = 4.0761%.
      assert html =~ ~s(left: 19.4293%)
      assert html =~ ~s(width: 4.0761%)
      # 24 hour-columns per day × 2 days = 48 columns.
      assert (html |> String.split("lg-col-header") |> length()) - 1 == 48
    end

    test "hour zoom highlights the current-hour column when today is a DateTime" do
      assigns = %{
        events: [],
        range: Date.range(~D[2026-04-01], ~D[2026-04-01]),
        today: ~N[2026-04-01 13:30:00]
      }

      html =
        render(
          ~H[<.gantt id="h" events={@events} date_range={@range} zoom={:hour} today={@today} />]
        )

      # Some hour column carries the today-highlight class (default
      # `column_header_today_class` = "bg-primary/10 ...").
      assert html =~ "lg-col-header"
      assert html =~ "bg-primary/10"
    end

    test "day_width_px overrides the per-zoom density (fit-to-width)" do
      events = [
        %LiveGantt.Task{id: "t", title: "X", start: ~D[2026-04-01], end: ~D[2026-04-02]}
      ]

      assigns = %{events: events, range: Date.range(~D[2026-04-01], ~D[2026-04-02])}

      # Coordinates are now % of content width (responsive), so `day_width_px`
      # sets the natural CONTENT width (the scroll min-width), not bar pixels.
      # Override 100px/day on a 2-day range → 200px of time axis + 2 × @axis_pad_px
      # (16) connector margin = min-width 232px. The 1-day bar (px 16..116) is
      # 100/232 = 43.1034% wide and still exactly covers its day column.
      html =
        render(
          ~H[<.gantt id="g" events={@events} date_range={@range} zoom={:day} day_width_px={100} />]
        )

      assert html =~ "min-width: 232px"
      assert html =~ "left: 6.8966%; width: 43.1034%"
    end

    test "default_day_width_px/1 exposes the per-zoom defaults" do
      assert LiveGantt.default_day_width_px(:hour) == 720
      assert LiveGantt.default_day_width_px(:day) == 40
      assert LiveGantt.default_day_width_px(:week) == 24
      assert LiveGantt.default_day_width_px(:month) == 8
    end

    test "today button is disabled when it can't actually scroll (no hooks, no handler)" do
      assigns = %{events: sample_events(), range: sample_range()}

      # id present but enable_hooks off + no on_scroll_today → the lg:scroll-today
      # dispatch has no listener, so the button is disabled, not silently dead.
      html =
        render(
          ~H[<.gantt id="g" events={@events} date_range={@range} show_header={true} on_zoom_change="z" />]
        )

      assert html =~ ~r/lg-today-btn[^>]*\sdisabled/
    end

    test "shows an off-screen Today hint at the edge instead of widening the axis" do
      # sample_range/0 is April 2026; today is far after → the axis stays put
      # and a right-edge 'Today →' hint appears. No today marker line (it would
      # have no in-range position).
      assigns = %{events: sample_events(), range: sample_range(), today: ~D[2026-12-25]}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} today={@today} />])

      assert html =~ "lg-today-edge"
      assert html =~ "Today →"
      # The vertical marker LINE (distinctive `w-0.5 bg-error`) is NOT drawn.
      refute html =~ "w-0.5 bg-error"

      # A today inside the range shows the marker line, not the edge hint.
      assigns = %{assigns | today: ~D[2026-04-15]}

      in_range =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} today={@today} />])

      refute in_range =~ "lg-today-edge"
      assert in_range =~ "w-0.5 bg-error"
    end

    test "today button is enabled with enable_hooks + id, or a custom on_scroll_today" do
      assigns = %{events: sample_events(), range: sample_range()}

      with_hooks =
        render(~H[<.gantt
  id="g"
  events={@events}
  date_range={@range}
  show_header={true}
  enable_hooks={true}
  on_zoom_change="z"
/>])

      with_handler =
        render(~H[<.gantt
  events={@events}
  date_range={@range}
  show_header={true}
  on_scroll_today="scroll"
  on_zoom_change="z"
/>])

      refute with_hooks =~ ~r/lg-today-btn[^>]*\sdisabled/
      refute with_handler =~ ~r/lg-today-btn[^>]*\sdisabled/
    end

    test "renders with custom label width" do
      assigns = %{events: sample_events(), range: sample_range()}

      html =
        render(~H"""
        <.gantt events={@events} date_range={@range} label_width="20rem" />
        """)

      assert html =~ "20rem"
    end

    test "renders event color dot in default label" do
      events = [
        %LiveGantt.Task{
          id: "c1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "Colored",
          color: "bg-warning"
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      assert html =~ "bg-warning"
    end

    test "renders week headers for week zoom" do
      range = Date.range(~D[2026-04-06], ~D[2026-05-03])
      assigns = %{events: [], range: range}

      html = render(~H"<.gantt events={[]} date_range={@range} zoom={:week} />")

      # Should show week numbers
      assert html =~ "W"
    end

    test "renders progress at 100% with success color" do
      events = [
        %LiveGantt.Task{
          id: "done",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "Done Task",
          color: "bg-primary",
          extra: %{progress_pct: 100}
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} />")

      assert html =~ "bg-success"
      assert html =~ "width: 100%"
    end

    test "hides progress when show_progress is false" do
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-10],
          title: "Task",
          color: "bg-primary",
          extra: %{progress_pct: 50}
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html = render(~H"<.gantt events={@events} date_range={@range} show_progress={false} />")

      refute html =~ "width: 50%"
    end
  end

  describe "window_start/window_end (sub-day positioning window)" do
    # A sub-day window over a DateTime task; date_range covers the same day.
    test "renders a task inside the window without crashing" do
      events = [
        %LiveGantt.Task{
          id: "t",
          title: "In window",
          start: ~N[2026-04-01 10:00:00],
          end: ~N[2026-04-01 12:00:00]
        }
      ]

      assigns = %{
        events: events,
        range: Date.range(~D[2026-04-01], ~D[2026-04-01]),
        ws: ~N[2026-04-01 09:00:00],
        we: ~N[2026-04-01 13:00:00]
      }

      html =
        render(~H[<.gantt
  id="w"
  events={@events}
  date_range={@range}
  zoom={:hour}
  window_start={@ws}
  window_end={@we}
/>])

      assert html =~ "lg-bar"
    end

    # Regression for the B1 crash: an event that's inside `date_range` but
    # OUTSIDE the positioning window must NOT reach `bar_geometry` as an admitted
    # event (partition and bar_geometry must share the window predicate), or the
    # template's strict `bar.milestone` access KeyErrors. The window starts at
    # 10:00; a 08:00–09:00 task is in-range for the whole-day date_range but
    # before the window.
    test "an in-date_range but out-of-window task is excluded, not crashed" do
      events = [
        %LiveGantt.Task{
          id: "before",
          title: "Before window",
          start: ~N[2026-04-01 08:00:00],
          end: ~N[2026-04-01 09:00:00]
        },
        %LiveGantt.Task{
          id: "inside",
          title: "Inside window",
          start: ~N[2026-04-01 11:00:00],
          end: ~N[2026-04-01 12:00:00]
        }
      ]

      assigns = %{
        events: events,
        range: Date.range(~D[2026-04-01], ~D[2026-04-01]),
        ws: ~N[2026-04-01 10:00:00],
        we: ~N[2026-04-01 14:00:00]
      }

      # Must not raise.
      html =
        render(~H[<.gantt
  id="w"
  events={@events}
  date_range={@range}
  zoom={:hour}
  window_start={@ws}
  window_end={@we}
  show_edge_indicators={true}
/>])

      assert html =~ "Inside window"
      refute html =~ "Before window"
    end

    # A degenerate window (end <= start) must be ignored, falling back to the
    # whole-day range, rather than producing a 0/negative axis that flags every
    # bar out-of-range.
    test "a non-positive window falls back to date_range" do
      events = [
        %LiveGantt.Task{id: "t", title: "T", start: ~D[2026-04-01], end: ~D[2026-04-02]}
      ]

      assigns = %{
        events: events,
        range: Date.range(~D[2026-04-01], ~D[2026-04-02]),
        ws: ~N[2026-04-01 12:00:00],
        we: ~N[2026-04-01 12:00:00]
      }

      html =
        render(~H[<.gantt
  id="w"
  events={@events}
  date_range={@range}
  zoom={:day}
  window_start={@ws}
  window_end={@we}
/>])

      assert html =~ "lg-bar"
    end

    test "a bare Date `today` shows under a sub-day window (H3)" do
      # window_start is intra-day (08:00); a bare Date today (no time) must be
      # treated as the whole day, so its line renders and no spurious "← Today"
      # edge pill appears — even though midnight sits before the 08:00 origin.
      events = [
        %LiveGantt.Task{
          id: "t",
          title: "T",
          start: ~N[2026-04-01 10:00:00],
          end: ~N[2026-04-01 12:00:00]
        }
      ]

      assigns = %{
        events: events,
        range: Date.range(~D[2026-04-01], ~D[2026-04-01]),
        ws: ~N[2026-04-01 08:00:00],
        we: ~N[2026-04-01 14:00:00],
        today: ~D[2026-04-01]
      }

      html =
        render(~H[<.gantt
  id="w"
  events={@events}
  date_range={@range}
  zoom={:hour}
  window_start={@ws}
  window_end={@we}
  today={@today}
  show_edge_indicators={true}
/>])

      assert html =~ "lg-today"
      refute html =~ "lg-today-edge"
    end

    test "a NaiveDateTime window drives the columns even when granularity demotes (M3)" do
      # An intra-day origin builds its headers from the WINDOW, not the date_range
      # — otherwise headers (date-range midnights) disagree with the
      # window-positioned bars. At :day zoom the budget-capped granularity is :day,
      # so a 2-day window yields 2 day columns — the WINDOW's span, not the 10-day
      # date_range's, and not an hourly smear (axis spacers carry no header class).
      events = [
        %LiveGantt.Task{
          id: "t",
          title: "T",
          start: ~N[2026-04-01 06:00:00],
          end: ~N[2026-04-01 10:00:00]
        }
      ]

      assigns = %{
        events: events,
        # 10-day date_range, deliberately wider than the 2-day window.
        range: Date.range(~D[2026-04-01], ~D[2026-04-10]),
        ws: ~N[2026-04-01 00:00:00],
        we: ~N[2026-04-03 00:00:00]
      }

      html =
        render(~H[<.gantt
  id="w"
  events={@events}
  date_range={@range}
  zoom={:day}
  window_start={@ws}
  window_end={@we}
/>])

      col_count = (html |> String.split("lg-col-header") |> length()) - 1
      # Window-driven (2, not the 10-day range's 10) and demoted to days (not a
      # 48-column hourly smear).
      assert col_count == 2, "expected 2 day columns, got #{col_count}"
    end

    test "a wide NaiveDateTime window demotes to day columns instead of smearing (N3)" do
      # The old fallback hardcoded hourly slots whenever the granularity demoted
      # below sub-day, so a wide NDT window produced one column PER HOUR — a
      # 60-day window meant ~1440 two-pixel columns. The budget-capped granularity
      # (:day here) must drive the slot, giving ~60 day columns.
      events = [
        %LiveGantt.Task{
          id: "t",
          title: "T",
          start: ~N[2026-04-01 06:00:00],
          end: ~N[2026-04-01 10:00:00]
        }
      ]

      assigns = %{
        events: events,
        range: Date.range(~D[2026-04-01], ~D[2026-06-01]),
        ws: ~N[2026-04-01 00:00:00],
        we: ~N[2026-05-31 00:00:00]
      }

      html =
        render(~H[<.gantt
  id="w2"
  events={@events}
  date_range={@range}
  zoom={:day}
  window_start={@ws}
  window_end={@we}
/>])

      col_count = (html |> String.split("lg-col-header") |> length()) - 1
      # 60 day columns + 2 spacers — emphatically not 60×24 hourly columns.
      assert col_count in 60..64, "expected ~60 day columns, got #{col_count}"
    end
  end

  describe "connector dependency types" do
    defp two_events(offset \\ 10) do
      [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "First",
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t2",
          start: Date.add(~D[2026-04-05], offset),
          end: Date.add(~D[2026-04-05], offset + 5),
          title: "Second",
          color: "bg-accent"
        }
      ]
    end

    test "defaults connector type to :fs and emits data-type" do
      connectors = [%{from: "t1", to: "t2"}]
      assigns = %{events: two_events(), range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ ~s(data-type="fs")
    end

    test "supports :ss (start-to-start) type" do
      connectors = [%{from: "t1", to: "t2", type: :ss}]
      assigns = %{events: two_events(), range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ ~s(data-type="ss")
    end

    test "supports :ff (finish-to-finish) type" do
      connectors = [%{from: "t1", to: "t2", type: :ff}]
      assigns = %{events: two_events(), range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ ~s(data-type="ff")
    end

    test "supports :sf (start-to-finish) type" do
      connectors = [%{from: "t1", to: "t2", type: :sf}]
      assigns = %{events: two_events(), range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ ~s(data-type="sf")
    end

    test ":ss with target-before-source routes forward (no detour) and still flags invalid" do
      # Target starts before source — SS constraint violated, but its stems
      # both exit west so the path stays a clean 3-segment, unlike FS.
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-15],
          end: ~D[2026-04-20],
          title: "Source",
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-05],
          end: ~D[2026-04-10],
          title: "Target",
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "t1", to: "t2", type: :ss}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # Marked invalid because schedule violates SS constraint
      assert html =~ ~s(data-invalid="true")
      assert html =~ "text-error"
    end
  end

  describe "connector tight-gap detour" do
    test "forward FS with tight gap routes via 5-segment detour for full-length stems" do
      # Milestone source + 3 targets starting the SAME day (0-gap FS — the
      # source exit and target entry land at the same x). The straight
      # 3-segment shape has no room for clean exit + approach stems, so the
      # builder switches to the 5-segment detour: `M x1 y H stem_out V dy H
      # stem_in V y2 H arrow_stop`. Both stems get the full @elbow_px (10) of
      # horizontal length.
      events = [
        %LiveGantt.Task{
          id: "ms",
          start: ~D[2026-04-21],
          end: ~D[2026-04-21],
          color: "bg-accent",
          extra: %{order: 1}
        },
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-21],
          end: ~D[2026-04-30],
          color: "bg-primary",
          extra: %{order: 2}
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-21],
          end: ~D[2026-05-02],
          color: "bg-primary",
          extra: %{order: 3}
        },
        %LiveGantt.Task{
          id: "c",
          start: ~D[2026-04-21],
          end: ~D[2026-04-28],
          color: "bg-primary",
          extra: %{order: 4}
        }
      ]

      connectors = [
        %{from: "ms", to: "a"},
        %{from: "ms", to: "b"},
        %{from: "ms", to: "c"}
      ]

      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # Parse the 5-segment detour path: M x1 y1 H stem_out V dy H stem_in V y2 H arrow_stop
      paths =
        Regex.scan(
          ~r/d="M (\d+) \d+ H (\d+) V (\d+) H (\d+) V \d+ H (\d+)"/,
          html
        )
        |> Enum.map(fn [_, x1, so, dy, si, stop] ->
          %{
            x1: String.to_integer(x1),
            stem_out: String.to_integer(so),
            detour_y: String.to_integer(dy),
            stem_in: String.to_integer(si),
            arrow_stop: String.to_integer(stop)
          }
        end)

      assert length(paths) == 3, "Expected 3 detour paths, got #{length(paths)}"

      Enum.each(paths, fn p ->
        assert p.stem_out - p.x1 == 10, "Expected 10px exit stem, got #{p.stem_out - p.x1}"

        assert p.arrow_stop - p.stem_in == 10,
               "Expected 10px approach stem, got #{p.arrow_stop - p.stem_in}"
      end)

      # Bus preserved: all three arrows share stem_out, detour_y, stem_in.
      assert paths |> Enum.map(& &1.stem_out) |> Enum.uniq() |> length() == 1
      assert paths |> Enum.map(& &1.detour_y) |> Enum.uniq() |> length() == 1
      assert paths |> Enum.map(& &1.stem_in) |> Enum.uniq() |> length() == 1

      # Tight-forward detour is NOT marked invalid (it's a valid
      # schedule, just a routing shape choice).
      refute html =~ ~s(data-invalid="true")
    end

    test "wide-gap FS still uses the 3-segment shape" do
      # 5-day FS gap at week zoom = 5*24 - 2 = 118px. Plenty of room
      # for the 3-segment shape; detour should NOT fire.
      events = [
        %LiveGantt.Task{
          id: "src",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "tgt",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "src", to: "tgt"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # 3-segment: only one V in the path.
      assert Regex.match?(~r/d="M \d+ \d+ H \d+ V \d+ H \d+"/, html)
      refute Regex.match?(~r/d="M \d+ \d+ H \d+ V \d+ H \d+ V \d+ H \d+"/, html)
    end

    test "forward path keeps a milestone target's approach ≥ head nudge (no detach)" do
      # Two FS arrows fan IN to a zero-duration milestone at a wide gap → forward
      # 3-segment path, and the fan-in preference would pull the trunk to
      # arrow_stop - @elbow_px (10px approach). The arrowhead is nudged
      # @milestone_edge_px (12) out, so a 10px approach strands it off the shaft.
      # The forward path must floor the approach at @milestone_edge_px + 2 = 14.
      events = [
        %LiveGantt.Task{id: "s1", start: ~D[2026-04-01], end: ~D[2026-04-03], extra: %{order: 1}},
        %LiveGantt.Task{id: "s2", start: ~D[2026-04-02], end: ~D[2026-04-04], extra: %{order: 2}},
        %LiveGantt.Task{id: "m", start: ~D[2026-04-20], end: ~D[2026-04-20], extra: %{order: 3}}
      ]

      connectors = [%{from: "s1", to: "m"}, %{from: "s2", to: "m"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      segs =
        Regex.scan(~r/d="M (\d+) \d+ H (\d+) V \d+ H (\d+)"/, html)
        |> Enum.map(fn [_, x1, mid, stop] ->
          {String.to_integer(x1), String.to_integer(mid), String.to_integer(stop)}
        end)

      assert length(segs) == 2, "expected 2 forward paths, got #{length(segs)}"

      Enum.each(segs, fn {x1, mid, stop} ->
        # The floor is folded into the router (not a post-clamp), so the exit
        # stem stays ≥ @min_exit_stem_px (6) AND the approach ≥ 14.
        assert stop - mid >= 14,
               "milestone-target approach #{stop - mid}px < 14px (head detaches)"

        assert mid - x1 >= 6, "exit stem #{mid - x1}px < @min_exit_stem_px (6)"
      end)
    end

    test "a tight gap into a milestone routes via detour (not a squished forward stem)" do
      # FS into a milestone needs exit (6) + approach (14) = 20px of gap for a
      # clean forward path. A narrower gap must fall to the 5-segment detour
      # rather than a forward path with a sub-6px exit stem. day_width_px=18 makes
      # the 1-day gap 18px (< 20).
      events = [
        %LiveGantt.Task{id: "s", start: ~D[2026-04-01], end: ~D[2026-04-05], extra: %{order: 1}},
        %LiveGantt.Task{id: "m", start: ~D[2026-04-06], end: ~D[2026-04-06], extra: %{order: 2}}
      ]

      connectors = [%{from: "s", to: "m"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(
          ~H"<.gantt events={@events} date_range={@range} connectors={@connectors} day_width_px={18} />"
        )

      # 5-segment detour has TWO vertical segments; a forward path has one.
      assert Regex.match?(~r/d="M \d+ \d+ H \d+ V \d+ H \d+ V \d+ H \d+"/, html),
             "tight milestone gap should route via detour"
    end
  end

  describe "connector critical flag" do
    test "renders critical connector with primary stroke and critical marker" do
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-06],
          end: ~D[2026-04-10],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "t1", to: "t2", critical: true}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ "text-primary"
      assert html =~ "lg-arrow-critical"
      assert html =~ ~s(data-critical="true")
    end

    test "invalid outranks critical — broken schedule stays red dashed" do
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-15],
          end: ~D[2026-04-25],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-05],
          end: ~D[2026-04-10],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "t1", to: "t2", critical: true}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # Invalid outranks critical: the connector is rendered as invalid
      # (data-invalid="true" + text-error color), not critical.
      assert html =~ ~s(data-invalid="true")
      assert Regex.match?(~r/lg-connector[^"]*text-error/, html)
      refute Regex.match?(~r/lg-connector[^"]*text-primary/, html)
    end
  end

  describe "connector labels" do
    test "renders label text when provided" do
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "t1", to: "t2", label: "5d lag"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ "lg-connector-label"
      assert html =~ "5d lag"
      # Halo stroke keeps the label readable over bars and lines
      assert html =~ "stroke-base-100"
      assert html =~ ~s(paint-order="stroke")
    end

    test "labeled FS uses detour when gap is too narrow for the label" do
      # Gap 1 day at week zoom = 22px. Label "2d buffer" ~54px wide, so
      # the trunk can't fit it horizontally between the bars — should
      # switch to detour so the label rides the horizontal leg instead.
      events = [
        %LiveGantt.Task{
          id: "s",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t",
          start: ~D[2026-04-06],
          end: ~D[2026-04-10],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "s", to: "t", label: "2d buffer"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # 5-segment detour path shape
      assert Regex.match?(~r/d="M \d+ \d+ H \d+ V \d+ H \d+ V \d+ H \d+"/, html)
    end

    test "vertical label orientation renders a rotation transform" do
      events = [
        %LiveGantt.Task{
          id: "s",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-primary",
          extra: %{order: 1}
        },
        %LiveGantt.Task{
          id: "t",
          start: ~D[2026-04-13],
          end: ~D[2026-04-18],
          color: "bg-accent",
          extra: %{order: 2}
        }
      ]

      connectors = [
        %{from: "s", to: "t", type: :ss, label: "side", label_orientation: :vertical}
      ]

      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # rotate(-90 cx cy) transform on both rect and text
      assert html =~ ~r/transform="rotate\(-90 \d+ \d+\)"/
    end

    test "smart label placement slides label along segment to avoid bars" do
      # Long detour leg with a bar centered on the leg midpoint — the
      # label should slide away from the obstacle rather than sit on it.
      events = [
        %LiveGantt.Task{
          id: "src",
          start: ~D[2026-04-28],
          end: ~D[2026-04-30],
          color: "bg-primary",
          extra: %{order: 1}
        },
        %LiveGantt.Task{
          id: "obs",
          start: ~D[2026-04-10],
          end: ~D[2026-04-18],
          color: "bg-warning",
          extra: %{order: 2}
        },
        %LiveGantt.Task{
          id: "tgt",
          start: ~D[2026-04-05],
          end: ~D[2026-04-08],
          color: "bg-accent",
          extra: %{order: 3}
        }
      ]

      connectors = [%{from: "src", to: "tgt", label: "lag"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # Label x extracted from the label <text> (attribute order: x first)
      [[_, lx_str]] =
        Regex.scan(~r/<text x="(\d+)"[^>]*lg-connector-label/, html)

      label_x = String.to_integer(lx_str)

      # Obstacle bar at x=[216, 408] (Apr 10 to 18 at week zoom). With
      # smart sliding the label should land outside that range (plus
      # small rect half-width clearance) instead of on top of it.
      assert label_x > 408 or label_x < 216,
             "Expected label_x=#{label_x} to slide clear of obstacle bar [216, 408]"
    end

    test "labeled SS pushes trunk further west so label clears source bar" do
      events = [
        %LiveGantt.Task{
          id: "s",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-primary",
          extra: %{order: 1}
        },
        %LiveGantt.Task{
          id: "t",
          start: ~D[2026-04-13],
          end: ~D[2026-04-18],
          color: "bg-accent",
          extra: %{order: 2}
        }
      ]

      connectors = [%{from: "s", to: "t", type: :ss, label: "parallel"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # Extract mid_x from the 3-segment SS path
      [[_, x1_str, mid_str]] =
        Regex.scan(~r/d="M (\d+) \d+ H (\d+) V/, html)
        |> Enum.filter(fn
          [_, _, _] -> true
          _ -> false
        end)

      x1 = String.to_integer(x1_str)
      mid = String.to_integer(mid_str)

      # Label "parallel" = 8 chars * 5 = 40px. Default SS offset = elbow
      # (10px); with label, offset = max(10, 40/2 + 10) = 30. So mid_x
      # should sit at x1 - 30 or further, not x1 - 10.
      assert x1 - mid >= 30,
             "Expected labeled SS trunk offset #{x1 - mid}px to be ≥ 30 (label_half + clearance)"
    end

    test "renders the background rect when label_background={:rect}" do
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "t1", to: "t2", label: "lag"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(
          ~H"<.gantt events={@events} date_range={@range} connectors={@connectors} label_background={:rect} />"
        )

      assert html =~ "lg-connector-label-bg"
      assert html =~ "fill-base-100"
    end

    test "omits the background rect by default (halo mode)" do
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "t1", to: "t2", label: "lag"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      refute html =~ "lg-connector-label-bg"
    end

    test "omits rect and text element when no label given" do
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t2",
          start: ~D[2026-04-06],
          end: ~D[2026-04-10],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "t1", to: "t2"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      refute html =~ "lg-connector-label"
    end
  end

  describe "per-connector styling overrides" do
    defp two_forward_events do
      [
        %LiveGantt.Task{
          id: "s",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-accent"
        }
      ]
    end

    test "color_class override replaces default color" do
      events = two_forward_events()
      connectors = [%{from: "s", to: "t", color_class: "text-success"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert Regex.match?(~r/lg-connector[^"]*text-success/, html)
    end

    test "stroke_width override replaces default thickness" do
      events = two_forward_events()
      connectors = [%{from: "s", to: "t", stroke_width: 4.0}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ ~s(stroke-width="4.0")
    end

    test "opacity override is applied to the path" do
      events = two_forward_events()
      connectors = [%{from: "s", to: "t", opacity: 0.5}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ ~s(opacity="0.5")
    end

    test "dasharray override is applied to the path" do
      events = two_forward_events()
      connectors = [%{from: "s", to: "t", dasharray: "8 2"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ ~s(stroke-dasharray="8 2")
    end
  end

  describe "component-level connector defaults" do
    test "connector_color_class changes default normal color" do
      events = [
        %LiveGantt.Task{
          id: "s",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "s", to: "t"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          connectors={@connectors}
          connector_color_class="text-warning"
          connector_stroke_width={2.5}
          connector_opacity={0.75}
        />
        """)

      assert Regex.match?(~r/lg-connector[^"]*text-warning/, html)
      assert html =~ ~s(stroke-width="2.5")
      assert html =~ ~s(opacity="0.75")
    end

    test "per-connector override beats component default" do
      events = [
        %LiveGantt.Task{
          id: "s",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "s", to: "t", color_class: "text-success"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          connectors={@connectors}
          connector_color_class="text-warning"
        />
        """)

      # Connector's explicit color wins over the component default
      assert Regex.match?(~r/lg-connector[^"]*text-success/, html)
      refute Regex.match?(~r/lg-connector[^"]*text-warning/, html)
    end
  end

  describe "per-connector routing overrides" do
    test "shape: :detour forces the 5-segment path even with a wide gap" do
      # 5-day gap is normally enough for 3-segment. shape: :detour forces detour.
      events = [
        %LiveGantt.Task{
          id: "s",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "t",
          start: ~D[2026-04-10],
          end: ~D[2026-04-15],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "s", to: "t", shape: :detour}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # 5-segment detour has two V segments
      assert Regex.match?(~r/d="M \d+ \d+ H \d+ V \d+ H \d+ V \d+ H \d+"/, html)
    end

    test "detour_side: :above forces the detour above the source row even when target is below" do
      events = [
        %LiveGantt.Task{
          id: "s",
          start: ~D[2026-04-20],
          end: ~D[2026-04-25],
          color: "bg-primary",
          extra: %{order: 1}
        },
        %LiveGantt.Task{
          id: "t",
          start: ~D[2026-04-05],
          end: ~D[2026-04-10],
          color: "bg-accent",
          extra: %{order: 2}
        }
      ]

      # Backward (target before source), target in row below — natural
      # detour_y would go below source. Force above.
      connectors = [%{from: "s", to: "t", detour_side: :above}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # Extract detour_y — should be ABOVE source center (20) since we forced :above.
      [[_, _, dy_str]] =
        Regex.scan(~r/d="M \d+ (\d+) H \d+ V (-?\d+)/, html)

      detour_y = String.to_integer(dy_str)
      assert detour_y < 20, "Expected detour_y=#{detour_y} to be above source y1 (20)"
    end

    test "exit_stem and entry_stem override the default elbow" do
      events = [
        %LiveGantt.Task{
          id: "s",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary",
          extra: %{order: 1}
        },
        %LiveGantt.Task{
          id: "t",
          start: ~D[2026-04-20],
          end: ~D[2026-04-25],
          color: "bg-accent",
          extra: %{order: 2}
        }
      ]

      # Backward connector forces detour, so the stem lengths come out
      # directly in the path d attribute. exit_stem=25, entry_stem=5.
      connectors = [%{from: "s", to: "t", shape: :detour, exit_stem: 25, entry_stem: 5}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # In 5-seg detour `M x1 y1 H stem_out`, stem_out = x1 + exit_stem. Every x
      # is shifted by @axis_pad_px (16) for the connector margin: x1 = 16 + 4*24 =
      # 112, stem_out = 137. arrow_stop = 16 + 19*24 = 472 (gap 0: the tip lands on
      # the target edge, the fixed-px arrowhead gives the separation). stem_in =
      # arrow_stop - entry_stem = 467.
      assert Regex.match?(~r/d="M 112 \d+ H 137 V \d+ H 467/, html)
    end

    test "avoid_collisions: false disables per-connector collision shifts" do
      # Similar setup to the collision scenario but with per-connector override
      events = [
        %LiveGantt.Task{
          id: "src",
          start: ~D[2026-04-01],
          end: ~D[2026-04-03],
          color: "bg-primary",
          extra: %{order: 1}
        },
        %LiveGantt.Task{
          id: "obstacle",
          start: ~D[2026-04-04],
          end: ~D[2026-04-18],
          color: "bg-warning",
          extra: %{order: 2}
        },
        %LiveGantt.Task{
          id: "tgt",
          start: ~D[2026-04-20],
          end: ~D[2026-04-25],
          color: "bg-accent",
          extra: %{order: 3}
        }
      ]

      connectors = [%{from: "src", to: "tgt", avoid_collisions: false}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # Without shifting, mid_x sits at the natural centered value inside
      # the obstacle's x-range [72, 408].
      [[_, _, mid_str]] = Regex.scan(~r/d="M (\d+) \d+ H (\d+) V/, html)
      mid_x = String.to_integer(mid_str)
      assert mid_x > 72 and mid_x < 408
    end
  end

  describe "bar + row customization attrs" do
    test "bar_class and bar_default_color_class override defaults" do
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "Task",
          color: nil
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          bar_class="absolute top-0 bottom-0 rounded-none flex items-center z-10"
          bar_default_color_class="bg-info"
        />
        """)

      # Default "bg-primary" replaced with "bg-info" for events without a color
      assert html =~ "bg-info"
      # Custom bar_class includes rounded-none
      assert html =~ "rounded-none"
    end

    test "status_*_class attrs override status styling" do
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          status: :tentative,
          title: "Task",
          color: "bg-primary"
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          status_tentative_class="border-4 border-dashed"
        />
        """)

      assert html =~ "border-dashed"
      # Default "opacity-60" no longer applied
      refute html =~ "opacity-60"
    end

    test "progress_complete_class overrides default complete-progress color" do
      events = [
        %LiveGantt.Task{
          id: "t1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-10],
          color: "bg-primary",
          extra: %{progress_pct: 100}
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          progress_complete_class="bg-info/60"
        />
        """)

      # New class applied for 100% progress fill
      assert html =~ "bg-info/60"
      # Default bg-success/40 not applied to the progress element
      refute html =~ "bg-success/40"
    end

    test "today_marker_line_class and today_marker_badge_class override today styling" do
      events = []
      today = ~D[2026-04-15]

      assigns = %{events: events, range: sample_range(), today: today}

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          today={@today}
          today_marker_line_class="absolute top-0 w-1 bg-warning z-30"
          today_marker_badge_class="bg-warning text-warning-content px-2"
        />
        """)

      assert html =~ "w-1 bg-warning"
      assert html =~ "bg-warning text-warning-content"
    end

    test "column_header_today_class overrides today-column highlight" do
      today = ~D[2026-04-15]
      assigns = %{events: [], range: sample_range(), today: today}

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          today={@today}
          column_header_today_class="bg-warning/20 text-warning font-black"
        />
        """)

      assert html =~ "bg-warning/20"
      assert html =~ "font-black"
    end

    test "milestone_class and milestone_default_color_class override milestone styling" do
      events = [
        %LiveGantt.Task{
          id: "m1",
          start: ~D[2026-04-15],
          end: ~D[2026-04-15],
          title: "Milestone",
          color: nil,
          icon: "◆"
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html =
        render(~H"""
        <.gantt
          events={@events}
          date_range={@range}
          milestone_class="absolute top-1/2 z-10 w-6 h-6 border-4"
          milestone_default_color_class="bg-secondary"
        />
        """)

      assert html =~ "w-6 h-6 border-4"
      assert html =~ "bg-secondary"
    end
  end

  describe "connector data attributes" do
    test "exposes from-id and to-id for hover-highlight CSS" do
      events = [
        %LiveGantt.Task{
          id: "from-abc",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "to-xyz",
          start: ~D[2026-04-06],
          end: ~D[2026-04-10],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "from-abc", to: "to-xyz"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      assert html =~ ~s(data-from-id="from-abc")
      assert html =~ ~s(data-to-id="to-xyz")
    end
  end

  describe "bar-collision avoidance" do
    # Setup: source on row 1, target on row 3. An "obstacle" bar on row 2
    # spans a wide horizontal range that contains the natural mid_x. With
    # avoidance on, the trunk must shift outside the obstacle's x-range.

    defp collision_scenario do
      # extra.order pins rows so the topological reorder doesn't move
      # "tgt" adjacent to "src" (which would skip past the obstacle row).
      events = [
        %LiveGantt.Task{
          id: "src",
          start: ~D[2026-04-01],
          end: ~D[2026-04-03],
          color: "bg-primary",
          extra: %{order: 1}
        },
        %LiveGantt.Task{
          id: "obstacle",
          start: ~D[2026-04-04],
          end: ~D[2026-04-18],
          color: "bg-warning",
          extra: %{order: 2}
        },
        %LiveGantt.Task{
          id: "tgt",
          start: ~D[2026-04-20],
          end: ~D[2026-04-25],
          color: "bg-accent",
          extra: %{order: 3}
        }
      ]

      connectors = [%{from: "src", to: "tgt"}]

      {events, connectors}
    end

    defp extract_mid_x(html) do
      case Regex.run(~r/d="M [\d\.\-]+ [\d\.\-]+ H ([\d\.\-]+) V/, html) do
        [_, x] -> String.to_integer(x)
        _ -> nil
      end
    end

    test "default avoid_collisions=true shifts trunk outside obstacle bar" do
      {events, connectors} = collision_scenario()
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      mid_x = extract_mid_x(html)
      refute is_nil(mid_x)

      # Obstacle occupies pixels [3*24, 17*24] = [72, 408] at week zoom
      # (Apr 4 minus Apr 1 = 3 days, Apr 18 minus Apr 1 = 17 days).
      # Trunk must land outside [72, 408] — either west (< 72) or east (> 408).
      refute mid_x > 72 and mid_x < 408,
             "Expected trunk at #{mid_x} to avoid obstacle range [72, 408]"
    end

    test "avoid_collisions=false leaves trunk at preferred (colliding) position" do
      {events, connectors} = collision_scenario()
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(
          ~H"<.gantt events={@events} date_range={@range} connectors={@connectors} avoid_collisions={false} />"
        )

      mid_x = extract_mid_x(html)
      refute is_nil(mid_x)

      # Without avoidance, the natural centered mid_x sits inside the
      # obstacle range [72, 408]. Source end is at day 2 (48px), target
      # start is at day 19 (456px) — centered mid = (48+456)/2 = 252,
      # squarely inside the obstacle.
      assert mid_x > 72 and mid_x < 408,
             "Expected trunk at #{mid_x} to sit inside obstacle range [72, 408] when avoidance off"
    end

    test "backward arrow pushes detour_y past obstructing bars instead of piercing them" do
      # Source east of everything, obstacle bars on intermediate rows whose
      # x-range covers stem_in (target.start - 12), target scheduled EARLIER
      # so the dep is backward. Preferred detour_y = source_bottom would
      # force the final vertical at stem_in through both obstacles;
      # detour_y must be pushed past obstacle2's bottom.
      events = [
        %LiveGantt.Task{
          id: "src",
          start: ~D[2026-04-30],
          end: ~D[2026-05-02],
          color: "bg-primary",
          extra: %{order: 1}
        },
        %LiveGantt.Task{
          id: "obstacle1",
          start: ~D[2026-04-10],
          end: ~D[2026-04-28],
          color: "bg-warning",
          extra: %{order: 2}
        },
        %LiveGantt.Task{
          id: "obstacle2",
          start: ~D[2026-04-12],
          end: ~D[2026-04-26],
          color: "bg-accent",
          extra: %{order: 3}
        },
        %LiveGantt.Task{
          id: "tgt",
          start: ~D[2026-04-22],
          end: ~D[2026-04-25],
          color: "bg-secondary",
          extra: %{order: 4}
        }
      ]

      connectors = [%{from: "src", to: "tgt"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # arrow_stop = tgt.start_px - 4 = 500 (21*24-4). stem_in = 490.
      # obstacle1 x=[9*24, 27*24]=[216, 648], contains 490. y_bottom=79.
      # obstacle2 x=[11*24, 25*24]=[264, 600], contains 490. y_bottom=119.
      # Preferred detour_y = 40. After push, detour_y > 119.
      detour_y =
        case Regex.run(~r/d="M [\d\.\-]+ [\d\.\-]+ H [\d\.\-]+ V ([\d\.\-]+)/, html) do
          [_, y] -> String.to_integer(y)
          _ -> nil
        end

      refute is_nil(detour_y)

      assert detour_y > 119,
             "Expected detour_y=#{detour_y} to be pushed past obstacle2's bottom (119)"
    end

    test "backward arrow keeps preferred detour_y when no obstructions at stem_in" do
      # Obstacles don't extend far enough east to cover stem_in — no push.
      events = [
        %LiveGantt.Task{
          id: "src2",
          start: ~D[2026-04-30],
          end: ~D[2026-05-02],
          color: "bg-primary",
          extra: %{order: 1}
        },
        %LiveGantt.Task{
          id: "narrow1",
          start: ~D[2026-04-10],
          end: ~D[2026-04-14],
          color: "bg-warning",
          extra: %{order: 2}
        },
        %LiveGantt.Task{
          id: "narrow2",
          start: ~D[2026-04-15],
          end: ~D[2026-04-18],
          color: "bg-accent",
          extra: %{order: 3}
        },
        %LiveGantt.Task{
          id: "tgt2",
          start: ~D[2026-04-22],
          end: ~D[2026-04-25],
          color: "bg-secondary",
          extra: %{order: 4}
        }
      ]

      connectors = [%{from: "src2", to: "tgt2"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      detour_y =
        case Regex.run(~r/d="M [\d\.\-]+ [\d\.\-]+ H [\d\.\-]+ V ([\d\.\-]+)/, html) do
          [_, y] -> String.to_integer(y)
          _ -> nil
        end

      # Preferred detour_y = source_bottom = 40. No push needed.
      assert detour_y == 40
    end

    test "falls back to preferred when no clean x exists in valid range" do
      # Two consecutive bars fully cover the valid FS range — no shift
      # possible. Arrow should still render (not crash) with preferred mid_x.
      events = [
        %LiveGantt.Task{
          id: "src",
          start: ~D[2026-04-01],
          end: ~D[2026-04-03],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "wall1",
          start: ~D[2026-04-03],
          end: ~D[2026-04-12],
          color: "bg-warning"
        },
        %LiveGantt.Task{
          id: "wall2",
          start: ~D[2026-04-12],
          end: ~D[2026-04-20],
          color: "bg-warning"
        },
        %LiveGantt.Task{
          id: "tgt",
          start: ~D[2026-04-20],
          end: ~D[2026-04-25],
          color: "bg-accent"
        }
      ]

      connectors = [%{from: "src", to: "tgt"}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # Should still render a connector path (graceful fallback)
      assert html =~ "lg-connectors"
      refute is_nil(extract_mid_x(html))
    end
  end

  describe "backward arrow lane staggering" do
    test "multiple backward arrows from same source get different detour_y" do
      # Three backward :fs connectors from a single source, all heading
      # down. Without lane staggering their detour segments would lie
      # exactly on top of each other.
      events = [
        %LiveGantt.Task{
          id: "src",
          start: ~D[2026-04-20],
          end: ~D[2026-04-30],
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          color: "bg-accent"
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-06],
          end: ~D[2026-04-10],
          color: "bg-secondary"
        },
        %LiveGantt.Task{id: "c", start: ~D[2026-04-11], end: ~D[2026-04-15], color: "bg-info"}
      ]

      connectors = [
        %{from: "src", to: "a"},
        %{from: "src", to: "b"},
        %{from: "src", to: "c"}
      ]

      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(~H"<.gantt events={@events} date_range={@range} connectors={@connectors} />")

      # Collect the `V <detour_y>` values from each invalid path's d attribute
      detour_ys =
        Regex.scan(~r/d="M [\d\.]+ [\d\.]+ H [\d\.]+ V ([\d\.]+)/, html)
        |> Enum.map(fn [_, y] -> y end)

      # With 3 backward arrows sharing source+direction, we expect 3 distinct detour_y values
      assert length(Enum.uniq(detour_ys)) == 3
    end
  end

  describe "bar popover (per-event actions)" do
    defp event_with_actions(actions) do
      %LiveGantt.Task{
        id: "t1",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Long task title that exceeds bar width",
        color: "bg-primary",
        extra: %{actions: actions}
      }
    end

    defp event_no_actions do
      %LiveGantt.Task{
        id: "t2",
        start: ~D[2026-04-12],
        end: ~D[2026-04-18],
        title: "Plain task",
        color: "bg-secondary"
      }
    end

    test "popover + hook always present so any bar can show its full title" do
      assigns = %{events: [event_no_actions()], range: sample_range()}
      html = render(~H"<.gantt events={@events} date_range={@range} />")

      # Popover is unconditional — every bar opens to reveal full title.
      assert html =~ "lg-bar-popover"
      assert html =~ "LgBarPopover"
      assert html =~ "data-popover-target"

      # ...but the actions row only appears when actions are configured.
      refute html =~ "lg-bar-popover-actions"
    end

    test "renders a clickable tiny-bar marker inside a container-query container" do
      assigns = %{events: [event_no_actions()], range: sample_range()}
      html = render(~H[<.gantt id="c" events={@events} date_range={@range} />])

      # Per-task container whose width tracks the bar's rendered width, made a
      # container-query target; the down-triangle marker lives inside it, wired
      # to the SAME popover so it's clickable.
      assert html =~ "lg-tiny-container"
      assert html =~ "container-type: inline-size"
      assert html =~ "lg-tiny-marker"
      assert html =~ "clip-path: polygon(0 0, 100% 0, 50% 100%)"
      assert html =~ ~s(data-popover-target="c-bar-popover-t2")

      # Visibility is PURE CSS — no JS: hidden by default, revealed by a
      # container query at the (default 5px) threshold.
      assert html =~ ".lg-tiny-marker{display:none}"
      assert html =~ "@container (max-width:5px)"
    end

    test "tiny_bar_px sets the container-query threshold" do
      assigns = %{events: [event_no_actions()], range: sample_range()}
      html = render(~H"<.gantt events={@events} date_range={@range} tiny_bar_px={12} />")

      assert html =~ "@container (max-width:12px)"
    end

    test "tiny_bar_px={0} disables the marker entirely" do
      assigns = %{events: [event_no_actions()], range: sample_range()}
      html = render(~H"<.gantt events={@events} date_range={@range} tiny_bar_px={0} />")

      refute html =~ "lg-tiny-marker"
      refute html =~ "lg-tiny-container"
      refute html =~ "@container"
    end

    test "renders popover with title + action button when actions present" do
      action = %{
        id: "comments",
        icon: "hero-chat-bubble-left",
        tooltip: "Open comments",
        phx_click: "open_comments"
      }

      assigns = %{events: [event_with_actions([action])], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      assert html =~ "lg-bar-popover"
      assert html =~ "LgBarPopover"
      assert html =~ ~s(data-popover-target="lg-bar-popover-t1")
      assert html =~ ~s(id="lg-bar-popover-t1")
      assert html =~ ~s(data-popover-for="lg-bar-t1")

      # Title rendered (full, not truncated)
      assert html =~ "Long task title that exceeds bar width"

      # Action button + tooltip + phx wiring
      assert html =~ ~s(class="hero-chat-bubble-left")
      assert html =~ ~s(title="Open comments")
      assert html =~ ~s(phx-click="open_comments")
      # event_id auto-included as phx-value-event-id
      assert html =~ ~s(phx-value-event-id="t1")
    end

    test "phx_value map keys expand to phx-value-* attrs" do
      action = %{
        icon: "hero-trash",
        tooltip: "Delete",
        phx_click: "delete_event",
        phx_value: %{event_id: "t1", source: "popover"}
      }

      assigns = %{events: [event_with_actions([action])], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      assert html =~ ~s(phx-value-event-id="t1")
      assert html =~ ~s(phx-value-source="popover")
      # The action's event id uses the hyphenated key (consistent with the
      # no-value path + the chevron), never the underscore form.
      refute html =~ "phx-value-event_id"
    end

    test "renders <a> when action has :href" do
      action = %{icon: "hero-link", tooltip: "View", href: "/events/t1"}

      assigns = %{events: [event_with_actions([action])], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      assert html =~ ~s(<a href="/events/t1")
      # The action itself is an <a>, not a <button> — scope to the action so
      # unrelated chrome buttons (toolbar, edge/today hints) don't false-fail.
      refute html =~ ~r/<button[^>]*lg-bar-action/
    end

    test "popover starts hidden (hidden class present in default class)" do
      action = %{icon: "hero-eye", tooltip: "Peek"}
      assigns = %{events: [event_with_actions([action])], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # Default bar_popover_class includes `hidden` so the JS hook can
      # toggle visibility without depending on initial inline styles.
      [_, popover_class_attr] =
        Regex.run(
          ~r/id="lg-bar-popover-t1"[^>]*class="([^"]+)"/,
          html
        )

      assert popover_class_attr =~ "hidden"
    end

    test "popover left aligns with bar left (frozen geometry)" do
      action = %{icon: "hero-eye", tooltip: "Peek"}
      assigns = %{events: [event_with_actions([action])], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # Extract bar's left and popover's left — should match exactly so
      # the popover anchors to the bar's left edge regardless of zoom.
      # Coords render as % of content width; bar + popover share the same %.
      [_, bar_left] =
        Regex.run(~r/id="lg-bar-t1"[^>]*style="left: ([\d.]+)%/, html)

      [_, pop_left] =
        Regex.run(
          ~r/id="lg-bar-popover-t1"[^>]*style="left: ([\d.]+)%/,
          html
        )

      assert bar_left == pop_left
    end

    test "non-list actions are ignored without crashing" do
      bad_event = %LiveGantt.Task{
        id: "weird",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Weird",
        color: "bg-primary",
        extra: %{actions: "not-a-list"}
      }

      assigns = %{events: [bad_event], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # Popover still renders (so the title can be read), but the bad
      # actions value is silently dropped — no actions row.
      assert html =~ "lg-bar-popover"
      refute html =~ "lg-bar-popover-actions"
    end

    test "popover min-width matches bar width so it visually extends the bar" do
      assigns = %{events: [event_no_actions()], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # bar width as % of content; popover min-width matches it.
      [_, bar_width] =
        Regex.run(~r/id="lg-bar-t2"[^>]*style="left: [\d.]+%; width: ([\d.]+)%/, html)

      [_, pop_min_width] =
        Regex.run(
          ~r/id="lg-bar-popover-t2"[^>]*style="[^"]*min-width: ([\d.]+)%/,
          html
        )

      assert bar_width == pop_min_width
    end

    test "popover title row inherits the bar's color class" do
      ev = %LiveGantt.Task{
        id: "tcolor",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Color test",
        color: "bg-warning"
      }

      assigns = %{events: [ev], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # Title row inside the popover carries the same color class as
      # the bar, so the popover looks like an extension of the task.
      [pop_inner] =
        Regex.run(
          ~r{id="lg-bar-popover-tcolor".*?</div>\s*</div>}s,
          html
        )

      assert pop_inner =~ "bg-warning"
      assert pop_inner =~ "lg-bar-popover-title"
    end

    test "popover wrapper inherits status, text_color, and event.class" do
      ev = %LiveGantt.Task{
        id: "tstatus",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Status test",
        color: "bg-secondary",
        text_color: "text-white",
        class: "ring-2",
        status: :pending_approval,
        extra: %{actions: [%{icon: "hero-eye", tooltip: "Peek"}]}
      }

      assigns = %{events: [ev], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      [popover_block] =
        Regex.run(
          ~r{id="lg-bar-popover-tstatus".*?</div>\s*</div>\s*</div>}s,
          html
        )

      # Color, text override, and event.class all reach the popover.
      assert popover_block =~ "bg-secondary"
      assert popover_block =~ "text-white"
      assert popover_block =~ "ring-2"

      # `:pending_approval` flash applies to the popover too.
      assert popover_block =~ "animate-pulse"

      # Both rows share the colored wrapper (single block — so they
      # pulse together rather than independently).
      assert popover_block =~ "lg-bar-popover-title"
      assert popover_block =~ "lg-bar-popover-actions"
    end

    test "cancelled status applies opacity + line-through to popover title" do
      ev = %LiveGantt.Task{
        id: "tcancelled",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Cancelled task",
        color: "bg-error",
        status: :cancelled
      }

      assigns = %{events: [ev], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      [popover_block] =
        Regex.run(
          ~r{id="lg-bar-popover-tcancelled".*?</div>\s*</div>}s,
          html
        )

      assert popover_block =~ "opacity-40"
      assert popover_block =~ "line-through"
    end

    test "popover has a border (visible against bars below)" do
      assigns = %{events: [event_no_actions()], range: sample_range()}
      html = render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      [_, popover_class] =
        Regex.run(~r/id="lg-bar-popover-t2"[^>]*class="([^"]+)"/, html)

      assert popover_class =~ ~r/\bborder\b/
    end

    test "subtitle shows assignee + progress when both relevant" do
      ev = %LiveGantt.Task{
        id: "tsub",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Subtitle test",
        color: "bg-primary",
        extra: %{assignee: "Alice", progress_pct: 80}
      }

      assigns = %{events: [ev], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      assert html =~ "lg-bar-popover-subtitle"
      assert html =~ "Alice"
      assert html =~ "80%"
      # Bullet separator between the two parts
      assert html =~ "Alice • 80%"
    end

    test "subtitle shows assignee only when no progress" do
      ev = %LiveGantt.Task{
        id: "tsub2",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Assignee only",
        color: "bg-primary",
        extra: %{assignee: "Bob"}
      }

      assigns = %{events: [ev], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      assert html =~ "lg-bar-popover-subtitle"
      assert html =~ "Bob"
      refute html =~ "•"
    end

    test "subtitle hidden when neither assignee nor progress is set" do
      ev = %LiveGantt.Task{
        id: "tsub3",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "No metadata",
        color: "bg-primary"
      }

      assigns = %{events: [ev], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      refute html =~ "lg-bar-popover-subtitle"
    end

    test "subtitle hidden when progress is 0 (not relevant)" do
      ev = %LiveGantt.Task{
        id: "tsub4",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Zero progress",
        color: "bg-primary",
        extra: %{progress_pct: 0}
      }

      assigns = %{events: [ev], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      refute html =~ "lg-bar-popover-subtitle"
    end

    test "label column row also gets a popover (same shape as bar)" do
      ev = %LiveGantt.Task{
        id: "twolab",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Long task with details",
        color: "bg-info",
        extra: %{
          assignee: "Alice",
          progress_pct: 75,
          actions: [%{id: "comments", icon: "hero-chat-bubble-left", phx_click: "open"}]
        }
      }

      assigns = %{events: [ev], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # Label gets an id, hook, and popover-target
      assert html =~ ~s(id="lg-label-twolab")
      assert html =~ ~s(data-popover-target="lg-label-popover-twolab")
      assert html =~ ~s(id="lg-label-popover-twolab")
      assert html =~ ~s(data-popover-for="lg-label-twolab")

      # Same wrapper styling as bar popover (color + status carry through)
      [label_pop_block] =
        Regex.run(
          ~r{id="lg-label-popover-twolab".*?</div>\s*</div>\s*</div>}s,
          html
        )

      assert label_pop_block =~ "bg-info"
      assert label_pop_block =~ "lg-label-popover-title"
      assert label_pop_block =~ "Long task with details"
      assert label_pop_block =~ "lg-label-popover-subtitle"
      assert label_pop_block =~ "Alice • 75%"
      assert label_pop_block =~ "lg-label-popover-actions"
    end

    test "label popover hidden by default + uses border-2 like the bar popover" do
      assigns = %{events: [event_no_actions()], range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      [_, label_pop_class] =
        Regex.run(~r/id="lg-label-popover-t2"[^>]*class="([^"]+)"/, html)

      assert label_pop_class =~ "hidden"
      assert label_pop_class =~ ~r/border-2/
    end

    test "bar badge renders as sibling with content + color + flash" do
      ev = %LiveGantt.Task{
        id: "tbadge",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Has badge",
        color: "bg-primary",
        extra: %{
          badges: [
            %{content: "5", color: "bg-error", flash: true},
            %{content: "NEW", corner: :bottom_left, color: "bg-success"}
          ]
        }
      }

      assigns = %{events: [ev], range: sample_range()}
      html = render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # Both badges present
      assert html =~ ~s(class="lg-bar-badge)
      # Content
      # Content is wrapped by HEEx whitespace — assert with regex.
      assert html =~ ~r/lg-bar-badge[^<]*>\s*5\s*</s
      assert html =~ ~r/lg-bar-badge[^<]*>\s*NEW\s*</s
      # Color + flash on the first badge
      assert html =~ "bg-error"
      assert html =~ "animate-pulse"
      # Second badge color
      assert html =~ "bg-success"
    end

    test "action button can carry a single :badge or list :badges" do
      ev = %LiveGantt.Task{
        id: "tactbadge",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Action with badge",
        color: "bg-primary",
        extra: %{
          actions: [
            %{
              icon: "hero-chat-bubble-left",
              tooltip: "Comments",
              phx_click: "open_comments",
              badge: %{content: "12"}
            }
          ]
        }
      }

      assigns = %{events: [ev], range: sample_range()}
      html = render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      assert html =~ "lg-action-badge"
      assert html =~ ~r/lg-action-badge[^<]*>\s*12\s*</s
      # Default color when none specified
      assert html =~ "bg-error"
    end

    test "non-list event badges are silently ignored" do
      bad = %LiveGantt.Task{
        id: "tbadbadge",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Bad badges",
        color: "bg-primary",
        extra: %{badges: "not-a-list"}
      }

      assigns = %{events: [bad], range: sample_range()}
      html = render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # No badge element rendered — bare string matches in <style>
      # blocks would yield false positives, so look for an actual span.
      refute html =~ ~r/<span[^>]*class="lg-bar-badge/
    end

    test "disabled action renders as <span>, not <button>, and drops phx-click" do
      ev = %LiveGantt.Task{
        id: "tdisabled",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Has disabled action",
        color: "bg-primary",
        extra: %{
          actions: [
            %{
              id: "approve",
              icon: "hero-check-circle",
              tooltip: "Cannot approve yet",
              phx_click: "wf_action_approve",
              disabled: true
            }
          ]
        }
      }

      assigns = %{events: [ev], range: sample_range()}
      html = render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # Action exists as a span (not button) carrying the disabled styling.
      [action_block] =
        Regex.run(
          ~r{<span[^>]*data-action-id="approve"[^>]*>.*?</span>}s,
          html
        )

      assert action_block =~ "aria-disabled=\"true\""
      assert action_block =~ "opacity-50"
      assert action_block =~ "cursor-not-allowed"
      assert action_block =~ "pointer-events-none"
      # Click handlers are NOT emitted.
      refute action_block =~ "phx-click"
      refute action_block =~ "wf_action_approve"
    end

    test "disabled action with :href doesn't render an anchor (no link)" do
      ev = %LiveGantt.Task{
        id: "tdisabledlink",
        start: ~D[2026-04-05],
        end: ~D[2026-04-10],
        title: "Disabled link",
        color: "bg-primary",
        extra: %{
          actions: [
            %{
              id: "view",
              icon: "hero-eye",
              tooltip: "Cannot view",
              href: "/some/path",
              disabled: true
            }
          ]
        }
      }

      assigns = %{events: [ev], range: sample_range()}
      html = render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # No anchor at all for the disabled action — render as span.
      refute html =~ ~s(href="/some/path")
      assert html =~ ~s(data-action-id="view")
      assert html =~ ~s(aria-disabled="true")
    end

    test "consumer can override popover styling via attrs" do
      action = %{icon: "hero-eye", tooltip: "Peek"}
      assigns = %{events: [event_with_actions([action])], range: sample_range()}

      html =
        render(~H"""
        <.gantt
          id="lg"
          events={@events}
          date_range={@range}
          bar_popover_class="custom-pop hidden"
          bar_action_button_class="custom-action-btn"
        />
        """)

      assert html =~ "custom-pop"
      assert html =~ "custom-action-btn"
    end
  end

  describe "sub-projects (parent_id roll-up)" do
    defp parent_with_children do
      base = ~D[2026-04-01]

      [
        # Parent has no end → rolled up from children
        %LiveGantt.Task{
          id: "p",
          start: base,
          end: nil,
          title: "Build wooden table",
          color: "bg-accent"
        },
        %LiveGantt.Task{
          id: "c1",
          start: Date.add(base, 0),
          end: Date.add(base, 3),
          title: "Cut wood",
          color: "bg-accent",
          extra: %{parent_id: "p"}
        },
        %LiveGantt.Task{
          id: "c2",
          start: Date.add(base, 3),
          end: Date.add(base, 6),
          title: "Assemble",
          color: "bg-accent",
          extra: %{parent_id: "p"}
        },
        %LiveGantt.Task{
          id: "c3",
          start: Date.add(base, 6),
          end: Date.add(base, 9),
          title: "Finish",
          color: "bg-accent",
          extra: %{parent_id: "p"}
        }
      ]
    end

    test "collapsed by default: only the parent roll-up bar renders" do
      assigns = %{events: parent_with_children(), range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # Parent label + bar present
      assert html =~ ~s(data-event-id="p")
      # Children's bars/labels are NOT rendered
      refute html =~ ~s(data-event-id="c1")
      refute html =~ ~s(data-event-id="c2")
      refute html =~ ~s(data-event-id="c3")
    end

    test "expanded: parent + every child rendered with chevron expanded" do
      assigns = %{
        events: parent_with_children(),
        range: sample_range(),
        expanded: MapSet.new(["p"])
      }

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} expanded={@expanded} />])

      assert html =~ ~s(data-event-id="p")
      assert html =~ ~s(data-event-id="c1")
      assert html =~ ~s(data-event-id="c2")
      assert html =~ ~s(data-event-id="c3")

      # Minus heroicon indicates expanded state
      assert html =~ "hero-minus-mini"
      refute html =~ "hero-plus-mini"
    end

    test "collapsed parent: chevron renders hero-plus-mini (collapsed marker)" do
      assigns = %{events: parent_with_children(), range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      assert html =~ "hero-plus-mini"
      refute html =~ "hero-minus-mini"
    end

    test "child indentation increases with nesting depth" do
      # Two levels: p → c1 (depth 1), c1 → grandchild (depth 2)
      events = [
        %LiveGantt.Task{id: "p", start: ~D[2026-04-01], end: nil, title: "Top"},
        %LiveGantt.Task{
          id: "c1",
          start: ~D[2026-04-01],
          end: nil,
          title: "Mid",
          extra: %{parent_id: "p"}
        },
        %LiveGantt.Task{
          id: "g1",
          start: ~D[2026-04-01],
          end: ~D[2026-04-03],
          title: "Leaf",
          extra: %{parent_id: "c1"}
        }
      ]

      assigns = %{
        events: events,
        range: sample_range(),
        expanded: MapSet.new(["p", "c1"])
      }

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} expanded={@expanded} />])

      # One vertical guide-line div per nesting depth — g1 is at
      # depth 2, c1 at depth 1, p at depth 0. Counting the guide-line
      # divs scoped to each label row confirms the indentation.
      guides_for = fn label_id ->
        ~r/id="#{label_id}".*?(?=id="lg-label|<\/div>\s*<\/div>\s*<\/div>\s*$)/s
        |> Regex.run(html)
        |> List.first()
        |> case do
          nil -> 0
          slice -> length(Regex.scan(~r/border-l-2 border-base-content\/20/, slice))
        end
      end

      assert guides_for.("lg-label-p") == 0
      assert guides_for.("lg-label-c1") == 1
      assert guides_for.("lg-label-g1") == 2
    end

    test "parent bar rolls up dates from children when own end is nil" do
      events = parent_with_children()

      assigns = %{events: events, range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # Children span Apr 1 → Apr 10 = 216px (9d × 24). Content width is the
      # 60-day sample_range × 24 + 2 × @axis_pad_px (16) = 1472px, and the bar x
      # is shifted by the pad: left (16 + 0)/1472 = 1.087%, width 216/1472 =
      # 14.6739%.
      assert html =~
               ~r/id="lg-bar-p"[^>]*style="left: 1.087%; width: 14.6739%/
    end

    test "sub-day children roll up to a parent BAR, not a midnight milestone" do
      events = [
        %LiveGantt.Task{id: "p", start: nil, end: nil, title: "Parent"},
        %LiveGantt.Task{
          id: "c1",
          start: ~N[2026-04-01 10:00:00],
          end: ~N[2026-04-01 12:00:00],
          title: "C1",
          extra: %{parent_id: "p"}
        },
        %LiveGantt.Task{
          id: "c2",
          start: ~N[2026-04-01 12:00:00],
          end: ~N[2026-04-01 14:00:00],
          title: "C2",
          extra: %{parent_id: "p"}
        }
      ]

      assigns = %{events: events, range: Date.range(~D[2026-04-01], ~D[2026-04-01])}

      html = render(~H[<.gantt id="lg" events={@events} date_range={@range} zoom={:hour} />])

      # The parent rolls up to 10:00–14:00 (a 4h span) — must render as a BAR
      # with width, NOT collapse to a zero-duration midnight milestone diamond.
      assert html =~ ~r/id="lg-bar-p"[^>]*lg-bar/
      refute html =~ ~r/id="lg-bar-p"[^>]*lg-milestone/
    end

    test "connector to a collapsed child retargets to the parent" do
      events =
        parent_with_children() ++
          [
            %LiveGantt.Task{
              id: "external",
              start: ~D[2026-04-12],
              end: ~D[2026-04-14],
              title: "Finish kitchen"
            }
          ]

      connectors = [%{from: "c3", to: "external", critical: true}]

      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html =
        render(
          ~H[<.gantt id="lg" events={@events} date_range={@range} connectors={@connectors} />]
        )

      # The arrow's data-from-id should be "p" (the parent) — not "c3"
      # — because c3 isn't visible while the sub-project is collapsed.
      assert html =~ ~s(data-from-id="p")
      assert html =~ ~s(data-to-id="external")
      refute html =~ ~s(data-from-id="c3")
    end

    test "connector between two children of the same collapsed parent is dropped" do
      connectors = [%{from: "c1", to: "c2"}]
      assigns = %{events: parent_with_children(), range: sample_range(), connectors: connectors}

      html =
        render(
          ~H[<.gantt id="lg" events={@events} date_range={@range} connectors={@connectors} />]
        )

      # Both endpoints would retarget to "p" → self-referential → skipped
      refute html =~ ~s(data-from-id="p")
      refute html =~ ~s(<path d="M )
    end

    test "expanded parent: child-to-child connector renders between the actual children" do
      connectors = [%{from: "c1", to: "c2"}]

      assigns = %{
        events: parent_with_children(),
        range: sample_range(),
        connectors: connectors,
        expanded: MapSet.new(["p"])
      }

      html =
        render(~H[<.gantt
  id="lg"
  events={@events}
  date_range={@range}
  connectors={@connectors}
  expanded={@expanded}
/>])

      assert html =~ ~s(data-from-id="c1")
      assert html =~ ~s(data-to-id="c2")
    end

    test "sub-project bar gets the bar_subproject_class styling" do
      assigns = %{events: parent_with_children(), range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      # Default sub-project class includes the repeating diagonal pattern
      assert html =~ "repeating-linear-gradient"
    end
  end

  describe "input edge cases (regression tests for crash bugs)" do
    test "cyclic parent_id chain renders without hanging" do
      events = [
        %LiveGantt.Task{
          id: "a",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "A",
          extra: %{parent_id: "b"}
        },
        %LiveGantt.Task{
          id: "b",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "B",
          extra: %{parent_id: "c"}
        },
        %LiveGantt.Task{
          id: "c",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "C",
          extra: %{parent_id: "a"}
        }
      ]

      task =
        Elixir.Task.async(fn ->
          assigns = %{events: events, range: sample_range()}
          render(~H[<.gantt id="lg" events={@events} date_range={@range} />])
        end)

      result = Elixir.Task.yield(task, 2_000) || Elixir.Task.shutdown(task, :brutal_kill)
      assert {:ok, html} = result, "render hung — cycle detection broken"
      # Cycle-closing link is dropped, so the chain becomes a proper
      # hierarchy with one root visible by default. The important thing
      # is the render finishes — anything in the HTML proves it ran.
      assert html =~ "lg-wrap"
    end

    test "self-referential parent_id doesn't hang" do
      events = [
        %LiveGantt.Task{
          id: "loop",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "Loop",
          extra: %{parent_id: "loop"}
        }
      ]

      task =
        Elixir.Task.async(fn ->
          assigns = %{events: events, range: sample_range()}
          render(~H[<.gantt id="lg" events={@events} date_range={@range} />])
        end)

      result = Elixir.Task.yield(task, 2_000) || Elixir.Task.shutdown(task, :brutal_kill)
      assert {:ok, html} = result, "render hung on self-referential parent_id"
      # Self-reference dropped → "loop" renders as a top-level task.
      assert html =~ ~s(data-event-id="loop")
    end

    test "event with nil start is silently dropped (no FunctionClauseError)" do
      events = [
        %LiveGantt.Task{
          id: "good",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "Good"
        },
        %LiveGantt.Task{id: "bad", start: nil, title: "Bad"}
      ]

      assigns = %{events: events, range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])

      assert html =~ ~s(data-event-id="good")
      refute html =~ ~s(data-event-id="bad")
    end

    test "duplicate event ids raise with a clear message" do
      events = [
        %LiveGantt.Task{
          id: "dup",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "First"
        },
        %LiveGantt.Task{
          id: "dup",
          start: ~D[2026-04-06],
          end: ~D[2026-04-10],
          title: "Second"
        }
      ]

      assert_raise ArgumentError, ~r/duplicate event ids.*dup/s, fn ->
        assigns = %{events: events, range: sample_range()}
        render(~H[<.gantt id="lg" events={@events} date_range={@range} />])
      end
    end
  end

  describe "sub-project rollup ordering" do
    test "parent with nil dates survives partition when children are in-range" do
      events = [
        %LiveGantt.Task{
          id: "p",
          start: nil,
          end: nil,
          title: "Parent",
          extra: %{children: true}
        },
        %LiveGantt.Task{
          id: "c1",
          start: ~D[2026-04-02],
          end: ~D[2026-04-06],
          title: "Child 1",
          extra: %{parent_id: "p"}
        },
        %LiveGantt.Task{
          id: "c2",
          start: ~D[2026-04-08],
          end: ~D[2026-04-15],
          title: "Child 2",
          extra: %{parent_id: "p"}
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} expanded={:all} />])

      # Parent must render — its dates are rolled up from the children
      # BEFORE partition runs (otherwise nil start drops it).
      assert html =~ ~s(data-event-id="p")
      assert html =~ ~s(data-event-id="c1")
      assert html =~ ~s(data-event-id="c2")
    end
  end

  describe "expanded: :all" do
    test "expands every sub-project in the input" do
      events = [
        %LiveGantt.Task{
          id: "p",
          start: ~D[2026-04-01],
          end: ~D[2026-04-30],
          title: "Parent"
        },
        %LiveGantt.Task{
          id: "c",
          start: ~D[2026-04-02],
          end: ~D[2026-04-06],
          title: "Child",
          extra: %{parent_id: "p"}
        }
      ]

      assigns = %{events: events, range: sample_range()}

      html_collapsed =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} expanded={nil} />])

      html_all =
        render(~H[<.gantt id="lg" events={@events} date_range={@range} expanded={:all} />])

      # Collapsed → child is hidden under the parent.
      refute html_collapsed =~ ~s(data-event-id="c")
      # `:all` → child is visible.
      assert html_all =~ ~s(data-event-id="c")
    end
  end

  describe "multi-instance isolation" do
    test "arrowheads render as a self-contained overlay, sharing no SVG defs" do
      events = sample_events()
      connectors = [%{from: "t1", to: "t2", type: :fs}]
      assigns = %{events: events, range: sample_range(), connectors: connectors}

      html_a =
        render(
          ~H[<.gantt id="alpha" events={@events} date_range={@range} connectors={@connectors} />]
        )

      html_b =
        render(
          ~H[<.gantt id="beta" events={@events} date_range={@range} connectors={@connectors} />]
        )

      # Each chart draws its own arrowhead overlay.
      assert html_a =~ "lg-arrowhead"
      assert html_b =~ "lg-arrowhead"

      # Arrowheads no longer rely on shared `<defs>`/`<marker>` entries or
      # `url(#...)` references — so two gantts on one page can't collide on
      # marker ids (the bug the old id-scoping guarded against is now structural).
      refute html_a =~ "<marker"
      refute html_a =~ "url(#"
      refute html_b =~ "url(#"
    end
  end

  describe "toggle_expanded/2" do
    test "adds an absent id and removes a present one in a MapSet" do
      assert LiveGantt.toggle_expanded(MapSet.new(), "a") == MapSet.new(["a"])
      assert LiveGantt.toggle_expanded(MapSet.new(["a", "b"]), "a") == MapSet.new(["b"])
    end

    test "normalizes nil and lists to a MapSet" do
      assert LiveGantt.toggle_expanded(nil, "a") == MapSet.new(["a"])
      assert LiveGantt.toggle_expanded(["a"], "b") == MapSet.new(["a", "b"])
      assert LiveGantt.toggle_expanded(["a", "b"], "a") == MapSet.new(["b"])
    end
  end

  describe "min_bar_px (M8 coverage)" do
    # A 1-hour task on a 60-day sample_range at :month zoom (day_px = 8) has a
    # true width of round((1/24) * 8) = 0px. content_width = round(60 * 8) +
    # 2 * 16 = 512px, so the 4px floor renders as 4/512 = 0.7813%.
    defp tiny_task do
      %LiveGantt.Task{
        id: "tiny",
        title: "Tiny",
        start: ~N[2026-04-01 09:00:00],
        end: ~N[2026-04-01 10:00:00],
        color: "bg-primary"
      }
    end

    defp bar_width_pct(html) do
      [_, w] =
        Regex.run(~r/class="lg-bar[^"]*"\s+style="left: [\d.]+%; width: ([\d.]+)%"/, html)

      String.to_float(w)
    end

    test "floors a sub-pixel bar to min_bar_px when set" do
      assigns = %{events: [tiny_task()], range: sample_range()}

      html =
        render(~H[<.gantt events={@events} date_range={@range} zoom={:month} min_bar_px={4} />])

      # content_width = round(60 * 8) + 2 * 16 = 512px. 4px floor = 0.78125%.
      expected_floor_pct = 4 / 512 * 100
      assert bar_width_pct(html) >= expected_floor_pct
      assert html =~ "width: 0.7813%"
    end

    test "default min_bar_px (0) leaves a sub-pixel bar as an honest hairline" do
      assigns = %{events: [tiny_task()], range: sample_range()}

      floored =
        render(~H[<.gantt events={@events} date_range={@range} zoom={:month} min_bar_px={4} />])

      honest = render(~H[<.gantt events={@events} date_range={@range} zoom={:month} />])

      # Honest hairline is narrower than the 4px-floored bar.
      assert bar_width_pct(honest) < bar_width_pct(floored)
      assert honest =~ "width: 0.0%"
    end
  end

  describe "sub-day zooms (M8 coverage)" do
    defp one_day_range, do: Date.range(~D[2026-04-01], ~D[2026-04-01])

    defp two_hour_task do
      %LiveGantt.Task{
        id: "t",
        title: "T",
        start: ~N[2026-04-01 00:00:00],
        end: ~N[2026-04-01 02:00:00],
        color: "bg-primary"
      }
    end

    defp col_count(html), do: (html |> String.split("lg-col-header") |> length()) - 1

    test ":min15 renders 96 columns/day with clock-time labels" do
      assigns = %{events: [two_hour_task()], range: one_day_range()}

      html = render(~H[<.gantt events={@events} date_range={@range} zoom={:min15} />])

      # 1-day range × 96 slots/day = 96 columns.
      assert col_count(html) == 96
      # Every quarter-hour boundary gets a clock-time label (not just the first).
      assert html =~ "0:15"
      assert html =~ "0:45"
      assert html =~ "1:30"
    end

    test ":min5 renders 288 columns/day" do
      assigns = %{events: [two_hour_task()], range: one_day_range()}

      html = render(~H[<.gantt events={@events} date_range={@range} zoom={:min5} />])

      # 1-day range × 288 slots/day = 288 columns.
      assert col_count(html) == 288
      # :15 clock boundaries still labelled at this finer zoom; the in-between
      # 5-minute ticks stay blank (no "0:05"/"0:10" labels).
      assert html =~ "0:15"
      refute html =~ "0:05"
    end
  end

  describe "dir / RTL (M8 coverage)" do
    test "dir={:rtl} puts dir=\"rtl\" on the root wrapper" do
      assigns = %{events: sample_events(), range: sample_range()}

      html = render(~H[<.gantt events={@events} date_range={@range} dir={:rtl} />])

      assert html =~ ~s(dir="rtl")
    end

    test "defaults to dir=\"ltr\"" do
      assigns = %{events: sample_events(), range: sample_range()}

      html = render(~H[<.gantt events={@events} date_range={@range} />])

      assert html =~ ~s(dir="ltr")
      refute html =~ ~s(dir="rtl")
    end
  end

  describe "mix live_gantt.dump (M8 coverage)" do
    test "runs without raising for a built-in fixture and prints geometry" do
      output =
        capture_io(fn ->
          Dump.run(["simple"])
        end)

      # The dump pretty-prints the structured geometry sections.
      assert output =~ "Rows"
      assert output =~ "Connectors"
      assert output =~ "forward:"
    end

    test "Inspector geometry of a dump fixture exposes the documented keys" do
      # The dump renders a fixture and runs it through Inspector.inspect_html;
      # assert that shape carries the geometry keys the task relies on.
      events = [
        %LiveGantt.Task{id: "a", start: ~D[2026-05-01], end: ~D[2026-05-06], color: "bg-primary"},
        %LiveGantt.Task{id: "b", start: ~D[2026-05-07], end: ~D[2026-05-11], color: "bg-primary"}
      ]

      html =
        LiveGantt.TestHelpers.render_waterfall(events, connectors: [%{from: "a", to: "b"}])

      geom = LiveGantt.Inspector.inspect_html(html)

      for key <- [:rows, :bars, :connectors, :arrowheads, :edges] do
        assert Map.has_key?(geom, key), "expected geometry key #{inspect(key)}"
      end

      assert is_list(geom.rows)
      assert is_map(geom.bars)
      assert %{earlier: _, later: _} = geom.edges
    end
  end

  describe "i18n overrides (M1 regression)" do
    test "month_names_short override renders in the month-zoom header" do
      range = Date.range(~D[2026-04-01], ~D[2026-04-30])

      events = [
        %LiveGantt.Task{id: "t", title: "T", start: ~D[2026-04-05], end: ~D[2026-04-10]}
      ]

      assigns = %{events: events, range: range}

      html =
        render(~H[<.gantt
  events={@events}
  date_range={@range}
  zoom={:month}
  translations={%{month_names_short: %{4 => "Avril"}}}
/>])

      assert html =~ "Avril"
      refute html =~ ">Apr<"
    end

    test "labels.task override renders as the label-column header" do
      range = Date.range(~D[2026-04-01], ~D[2026-04-30])

      events = [
        %LiveGantt.Task{id: "t", title: "T", start: ~D[2026-04-05], end: ~D[2026-04-10]}
      ]

      assigns = %{events: events, range: range}

      html =
        render(~H[<.gantt
  events={@events}
  date_range={@range}
  show_header={true}
  on_zoom_change="z"
  translations={%{labels: %{task: "Tâche"}}}
/>])

      assert html =~ "Tâche"
    end
  end

  describe "Layout.sequential cycle (M2 regression)" do
    test "includes every id even with a parent_id cycle" do
      # a's parent is b, b's parent is a (a 2-node cycle), plus a normal c.
      # The tree walk never reaches a/b through the root; the missing-id pass
      # must still lay them out so none are dropped.
      items = [
        %{id: "a", parent_id: "b", duration: 2, start: ~D[2026-04-01]},
        %{id: "b", parent_id: "a", duration: 2, start: ~D[2026-04-01]},
        %{id: "c", parent_id: nil, duration: 2, start: ~D[2026-04-01]}
      ]

      result =
        LiveGantt.Layout.sequential(items,
          start: ~D[2026-04-01],
          id: & &1.id,
          parent_id: & &1.parent_id,
          duration: & &1.duration
        )

      assert Map.has_key?(result, "a")
      assert Map.has_key?(result, "b")
      assert Map.has_key?(result, "c")
      assert Map.keys(result) |> Enum.sort() == ["a", "b", "c"]
    end

    test "a cycle of nil-duration sub-project heads lays out flat (no crash)" do
      # Cycle members that *head* a sub-tree carry no usable duration — a nil
      # duration would hit `advance` arithmetic on nil. The flat pass must treat
      # nil as "no duration" and give each a min_span slot instead of crashing.
      items = [
        %{id: "a", parent_id: "b", duration: nil},
        %{id: "b", parent_id: "a", duration: nil},
        %{id: "c", parent_id: nil, duration: 2}
      ]

      result =
        LiveGantt.Layout.sequential(items,
          start: ~D[2026-04-01],
          id: & &1.id,
          parent_id: & &1.parent_id,
          duration: & &1.duration
        )

      assert Map.keys(result) |> Enum.sort() == ["a", "b", "c"]
      # nil-duration members get a >= min_span (1 day) slot, not a zero/negative bar.
      assert Date.diff(result["a"].end, result["a"].start) >= 1
      assert Date.diff(result["b"].end, result["b"].start) >= 1
    end

    test "a cycle whose accessor raises (no :duration key) still lays out flat" do
      # Default duration accessor is `& &1.duration`; a map lacking that key would
      # raise KeyError mid-layout. The flat pass rescues the accessor and falls
      # back to a min_span slot rather than taking down the whole chart.
      items = [
        %{id: "a", parent_id: "b"},
        %{id: "b", parent_id: "a"},
        %{id: "c", parent_id: nil, duration: 2}
      ]

      result =
        LiveGantt.Layout.sequential(items,
          start: ~D[2026-04-01],
          id: & &1.id,
          parent_id: & &1.parent_id
        )

      assert Map.keys(result) |> Enum.sort() == ["a", "b", "c"]
    end
  end

  describe "a11y + hook gating (M5 regression)" do
    defp a11y_events do
      [
        %LiveGantt.Task{
          id: "bar",
          start: ~D[2026-04-01],
          end: ~D[2026-04-05],
          title: "Bar",
          color: "bg-primary"
        },
        %LiveGantt.Task{
          id: "ms",
          start: ~D[2026-04-10],
          end: ~D[2026-04-10],
          title: "Milestone",
          color: "bg-success"
        }
      ]
    end

    test "enable_hooks=true adds tabindex + role=button to bars/milestones" do
      assigns = %{events: a11y_events(), range: sample_range()}

      html =
        render(~H[<.gantt id="g" events={@events} date_range={@range} enable_hooks={true} />])

      assert html =~ ~s(tabindex="0")
      assert html =~ ~s(role="button")
    end

    test "enable_hooks adds keyboard a11y attrs to label rows too (N7)" do
      assigns = %{events: a11y_events(), range: sample_range()}

      html =
        render(~H[<.gantt id="g" events={@events} date_range={@range} enable_hooks={true} />])

      # The label row carries the LgBarPopover hook, so it must also be
      # keyboard-focusable and announced as a popover trigger — same as the bars.
      [label_tag] = Regex.run(~r/<div[^>]*class="lg-label[ "][^>]*>/, html)
      assert label_tag =~ ~s(tabindex="0")
      assert label_tag =~ ~s(role="button")
      assert label_tag =~ ~s(aria-haspopup="dialog")
    end

    test "enable_hooks=false (default) omits tabindex/role on bars" do
      assigns = %{events: a11y_events(), range: sample_range()}

      html = render(~H[<.gantt id="g" events={@events} date_range={@range} />])

      refute html =~ ~s(tabindex="0")
    end

    test "enable_hooks gates the LgBarPopover hook" do
      assigns = %{events: a11y_events(), range: sample_range()}

      with_hooks =
        render(~H[<.gantt id="g" events={@events} date_range={@range} enable_hooks={true} />])

      without_hooks = render(~H[<.gantt id="g" events={@events} date_range={@range} />])

      assert with_hooks =~ ~s(phx-hook="LgBarPopover")
      refute without_hooks =~ ~s(phx-hook="LgBarPopover")
    end
  end
end
