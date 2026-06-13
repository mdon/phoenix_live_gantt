defmodule Mix.Tasks.PhoenixLiveGantt.Dump do
  @shortdoc "Dump structured geometry for a PhoenixLiveGantt fixture (debug aid)"

  @moduledoc """
  Render a named PhoenixLiveGantt fixture and pretty-print its geometry to
  stdout. Use this to debug "what does this chart actually look like?"
  without running the dev server.

      mix phoenix_live_gantt.dump                    # list fixtures
      mix phoenix_live_gantt.dump simple
      mix phoenix_live_gantt.dump fanout
      mix phoenix_live_gantt.dump fanout --stagger 4
      mix phoenix_live_gantt.dump fanout --zoom day

  Options:
    --zoom day|week|month  (default: week)
    --stagger N            (default: 0)  outgoing+incoming bus stagger
    --expanded a,b,c       comma-separated sub-project ids to render in
                           the EXPANDED state (default: all collapsed)
    --expanded *           expand every sub-project
    --raw                  also print the raw HTML below the structured dump
  """

  use Mix.Task
  use Phoenix.Component

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixLiveGantt.Inspector
  alias PhoenixLiveGantt.TestHelpers

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          zoom: :string,
          stagger: :integer,
          raw: :boolean,
          expanded: :string
        ],
        aliases: [z: :zoom, s: :stagger, e: :expanded]
      )

    case positional do
      [] ->
        list_fixtures()

      [name | _] ->
        case fetch_fixture(name) do
          {:ok, fixture} ->
            dump(name, fixture, opts)

          :error ->
            Mix.shell().error("Unknown fixture: #{name}\n")
            list_fixtures()
        end
    end
  end

  # -- Fixtures --

  defp list_fixtures do
    Mix.shell().info("""
    Available fixtures:
      simple    — 3 tasks, single FS chain
      fanout    — 1 source, 5 outgoing FS targets (component-library style)
      fanin     — 5 sources, 1 target with FF fan-in (frontend-qa style)
      mixed     — Hub with both incoming and outgoing on the same side
      conflict  — Backward FS arrow (target scheduled before source-end)
      all_types — 4 connectors covering :fs, :ss, :ff, :sf
      demo      — Subset of the phoenix_kit demo: 7-way fan-out hub +
                  7-way :ff fan-in, with cross-group critical chain.
                  Best for stress-testing real production scenarios.

    Usage: mix phoenix_live_gantt.dump <fixture_name> [--zoom week] [--stagger N] [--raw]
    """)
  end

  defp fetch_fixture(name) do
    today = ~D[2026-05-01]
    d = &Date.add(today, &1)

    case name do
      "simple" ->
        events = [
          ev("a", d.(0), d.(5)),
          ev("b", d.(6), d.(10)),
          ev("c", d.(11), d.(15))
        ]

        connectors = [
          %{from: "a", to: "b", critical: true},
          %{from: "b", to: "c"}
        ]

        {:ok, {events, connectors, today}}

      "fanout" ->
        events = [
          ev("hub", d.(0), d.(10)),
          ev("t1", d.(11), d.(15)),
          ev("t2", d.(11), d.(15)),
          ev("t3", d.(11), d.(15)),
          ev("t4", d.(11), d.(15)),
          ev("t5", d.(11), d.(15))
        ]

        connectors = [
          %{from: "hub", to: "t1", critical: true},
          %{from: "hub", to: "t2"},
          %{from: "hub", to: "t3"},
          %{from: "hub", to: "t4", critical: true},
          %{from: "hub", to: "t5"}
        ]

        {:ok, {events, connectors, today}}

      "fanin" ->
        events = [
          ev("s1", d.(0), d.(5)),
          ev("s2", d.(0), d.(5)),
          ev("s3", d.(0), d.(5)),
          ev("s4", d.(0), d.(5)),
          ev("s5", d.(0), d.(5)),
          ev("hub", d.(6), d.(10))
        ]

        connectors = [
          %{from: "s1", to: "hub", type: :ff},
          %{from: "s2", to: "hub", type: :ff},
          %{from: "s3", to: "hub", type: :ff, critical: true},
          %{from: "s4", to: "hub", type: :ff},
          %{from: "s5", to: "hub", type: :ff}
        ]

        {:ok, {events, connectors, today}}

      "mixed" ->
        events = [
          ev("upstream", d.(0), d.(5)),
          ev("hub", d.(6), d.(12)),
          ev("downstream", d.(13), d.(18))
        ]

        connectors = [
          # upstream → hub on hub's WEST side (incoming)
          %{from: "upstream", to: "hub"},
          # hub → downstream on hub's EAST side (outgoing)
          %{from: "hub", to: "downstream"}
        ]

        {:ok, {events, connectors, today}}

      "conflict" ->
        events = [
          ev("source", d.(5), d.(15)),
          # target ends BEFORE source ends — backward arrow
          ev("target", d.(0), d.(8))
        ]

        connectors = [%{from: "source", to: "target"}]
        {:ok, {events, connectors, today}}

      "all_types" ->
        events = [
          ev("a", d.(0), d.(5)),
          ev("b", d.(8), d.(12)),
          ev("c", d.(15), d.(20)),
          ev("d", d.(22), d.(28))
        ]

        connectors = [
          %{from: "a", to: "b", type: :fs, label: "FS"},
          %{from: "a", to: "c", type: :ss, label: "SS"},
          %{from: "b", to: "d", type: :ff, label: "FF"},
          %{from: "c", to: "d", type: :sf, label: "SF"}
        ]

        {:ok, {events, connectors, today}}

      "demo" ->
        {:ok, {full_demo_events(d), full_demo_connectors(), today}}

      _ ->
        :error
    end
  end

  defp ev(id, start_d, end_d, opts \\ []) do
    %PhoenixLiveGantt.Task{
      id: id,
      start: start_d,
      end: end_d,
      color: Keyword.get(opts, :color, "bg-primary"),
      category: Keyword.get(opts, :category, ""),
      icon: Keyword.get(opts, :icon),
      status: Keyword.get(opts, :status, :active),
      extra: Keyword.get(opts, :extra, %{})
    }
  end

  # ---- Full phoenix_kit demo mirror ----
  # Kept in sync with `phoenix_kit/lib/phoenix_kit_web/live/calendar_demo.ex`'s
  # `generate_waterfall_events/1` and `generate_waterfall_connectors/0`.
  # When the actual demo changes, update this fixture so audit results
  # reflect the production layout.

  defp full_demo_events(d) do
    [
      # Phase 1: Discovery
      ev("wf-stakeholders", d.(0), d.(5), color: "bg-info", category: "Phase 1: Discovery"),
      ev("wf-market-research", d.(2), d.(7), color: "bg-info", category: "Phase 1: Discovery"),
      ev("wf-competitive", d.(1), d.(5), color: "bg-info", category: "Phase 1: Discovery"),
      ev("wf-personas", d.(5), d.(9), color: "bg-info", category: "Phase 1: Discovery"),
      ev("wf-discovery-readout", d.(9), d.(11), color: "bg-info", category: "Phase 1: Discovery"),
      ev("wf-discovery-signoff", d.(12), d.(12),
        color: "bg-info",
        icon: "◆",
        category: "Phase 1: Discovery"
      ),
      # Phase 2: Design
      ev("wf-ia", d.(13), d.(19), color: "bg-accent", category: "Phase 2: Design"),
      # Sub-project (no explicit end date — auto-rolled from children)
      ev("wf-design-system", d.(13), nil, color: "bg-accent", category: "Phase 2: Design"),
      ev("wf-ds-foundation", d.(13), d.(17),
        color: "bg-accent",
        category: "Phase 2: Design",
        extra: %{parent_id: "wf-design-system"}
      ),
      # Nested sub-project (depth 2): rolls up over the 3 ds-comp-* events
      ev("wf-ds-components", d.(17), nil,
        color: "bg-accent",
        category: "Phase 2: Design",
        extra: %{parent_id: "wf-design-system"}
      ),
      ev("wf-ds-comp-primitives", d.(17), d.(19),
        color: "bg-accent",
        category: "Phase 2: Design",
        extra: %{parent_id: "wf-ds-components"}
      ),
      ev("wf-ds-comp-overlays", d.(18), d.(20),
        color: "bg-accent",
        category: "Phase 2: Design",
        extra: %{parent_id: "wf-ds-components"}
      ),
      ev("wf-ds-comp-data", d.(19), d.(21),
        color: "bg-accent",
        category: "Phase 2: Design",
        extra: %{parent_id: "wf-ds-components"}
      ),
      ev("wf-ds-docs", d.(21), d.(23),
        color: "bg-accent",
        category: "Phase 2: Design",
        extra: %{parent_id: "wf-design-system"}
      ),
      ev("wf-wf-landing", d.(20), d.(25), color: "bg-accent", category: "Phase 2: Design"),
      ev("wf-wf-dashboard", d.(20), d.(27), color: "bg-accent", category: "Phase 2: Design"),
      ev("wf-wf-settings", d.(22), d.(26), color: "bg-accent", category: "Phase 2: Design"),
      ev("wf-mobile-mockups", d.(26), d.(34), color: "bg-accent", category: "Phase 2: Design"),
      ev("wf-desktop-mockups", d.(27), d.(35), color: "bg-accent", category: "Phase 2: Design"),
      ev("wf-design-qa", d.(35), d.(37), color: "bg-accent", category: "Phase 2: Design"),
      ev("wf-design-signoff", d.(37), d.(37),
        color: "bg-accent",
        icon: "◆",
        category: "Phase 2: Design"
      ),
      # Phase 3: Backend
      ev("wf-db-schema", d.(23), d.(27), category: "Phase 3: Backend"),
      ev("wf-db-migrations", d.(27), d.(30), category: "Phase 3: Backend"),
      ev("wf-auth-service", d.(30), d.(38), category: "Phase 3: Backend"),
      ev("wf-search-api", d.(28), d.(40), category: "Phase 3: Backend"),
      ev("wf-notification-service", d.(30), d.(37), category: "Phase 3: Backend"),
      ev("wf-user-api", d.(38), d.(48), category: "Phase 3: Backend"),
      ev("wf-settings-api", d.(38), d.(44), category: "Phase 3: Backend"),
      ev("wf-payment-integration", d.(48), d.(58),
        category: "Phase 3: Backend",
        extra: %{
          badges: [
            %{content: "3", color: "bg-error", flash: true},
            %{content: "!", corner: :bottom_left, color: "bg-warning"}
          ],
          actions: [
            %{
              id: "comments",
              icon: "hero-chat-bubble-left-mini",
              tooltip: "Comments (3)",
              phx_click: "wf_action_comments",
              badge: %{content: "3", color: "bg-error", flash: true}
            },
            %{
              id: "assign",
              icon: "hero-user-plus-mini",
              tooltip: "Assign someone",
              phx_click: "wf_action_assign"
            },
            %{
              id: "details",
              icon: "hero-arrow-top-right-on-square-mini",
              tooltip: "Open details",
              phx_click: "wf_action_details"
            }
          ]
        }
      ),
      ev("wf-reporting-api", d.(48), d.(56), category: "Phase 3: Backend"),
      ev("wf-backend-integration", d.(56), d.(61), category: "Phase 3: Backend"),
      ev("wf-backend-freeze", d.(61), d.(61), icon: "◆", category: "Phase 3: Backend"),
      # Phase 4: Frontend
      ev("wf-fe-scaffold", d.(28), d.(33), color: "bg-secondary", category: "Phase 4: Frontend"),
      ev("wf-component-library", d.(38), d.(50),
        color: "bg-secondary",
        category: "Phase 4: Frontend",
        # Mirrors the demo's per-task stagger override on this hub
        extra: %{
          bus_stagger_outgoing_px: 4,
          actions: [
            %{
              id: "comments",
              icon: "hero-chat-bubble-left-mini",
              tooltip: "Comments (12)",
              phx_click: "wf_action_comments"
            },
            %{
              id: "approve",
              icon: "hero-check-circle-mini",
              tooltip: "Locked: pending design sign-off",
              phx_click: "wf_action_approve",
              class: "text-success",
              disabled: true
            }
          ]
        }
      ),
      ev("wf-auth-flows", d.(50), d.(56), color: "bg-secondary", category: "Phase 4: Frontend"),
      ev("wf-landing-page", d.(50), d.(55), color: "bg-secondary", category: "Phase 4: Frontend"),
      ev("wf-dashboard", d.(55), d.(65), color: "bg-secondary", category: "Phase 4: Frontend"),
      ev("wf-settings-page", d.(55), d.(61),
        color: "bg-secondary",
        category: "Phase 4: Frontend"
      ),
      ev("wf-search-ui", d.(50), d.(58), color: "bg-secondary", category: "Phase 4: Frontend"),
      ev("wf-payment-ui", d.(60), d.(67), color: "bg-secondary", category: "Phase 4: Frontend"),
      ev("wf-reports-ui", d.(56), d.(62), color: "bg-secondary", category: "Phase 4: Frontend"),
      ev("wf-frontend-qa", d.(65), d.(69), color: "bg-secondary", category: "Phase 4: Frontend"),
      ev("wf-frontend-freeze", d.(69), d.(69),
        color: "bg-secondary",
        icon: "◆",
        category: "Phase 4: Frontend"
      ),
      # Phase 5: Integration & QA
      ev("wf-cross-team", d.(65), d.(70),
        color: "bg-warning",
        category: "Phase 5: Integration & QA"
      ),
      ev("wf-security-audit", d.(65), d.(71),
        color: "bg-warning",
        category: "Phase 5: Integration & QA"
      ),
      # Top-level sub-project: rolls up over baseline/tuning/monitoring
      ev("wf-performance", d.(70), nil,
        color: "bg-warning",
        category: "Phase 5: Integration & QA"
      ),
      ev("wf-perf-baseline", d.(70), d.(72),
        color: "bg-warning",
        category: "Phase 5: Integration & QA",
        extra: %{parent_id: "wf-performance"}
      ),
      ev("wf-perf-tuning", d.(71), d.(73),
        color: "bg-warning",
        category: "Phase 5: Integration & QA",
        extra: %{parent_id: "wf-performance"}
      ),
      ev("wf-perf-monitoring", d.(72), d.(74),
        color: "bg-warning",
        category: "Phase 5: Integration & QA",
        extra: %{parent_id: "wf-performance"}
      ),
      ev("wf-load-testing", d.(74), d.(77),
        color: "bg-warning",
        category: "Phase 5: Integration & QA"
      ),
      ev("wf-bug-bash", d.(75), d.(78),
        color: "bg-warning",
        status: :pending_approval,
        category: "Phase 5: Integration & QA"
      ),
      ev("wf-preprod", d.(78), d.(78),
        color: "bg-warning",
        icon: "◆",
        category: "Phase 5: Integration & QA"
      ),
      # Phase 6: Launch
      ev("wf-documentation", d.(62), d.(72),
        color: "bg-success",
        status: :tentative,
        category: "Phase 6: Launch"
      ),
      ev("wf-legal-review", d.(70), d.(76), color: "bg-success", category: "Phase 6: Launch"),
      ev("wf-marketing", d.(75), d.(85), color: "bg-success", category: "Phase 6: Launch"),
      ev("wf-old-feature-removal", d.(73), d.(80),
        color: "bg-base-content/30",
        status: :cancelled,
        category: "Phase 6: Launch"
      ),
      ev("wf-beta-rollout", d.(78), d.(83), color: "bg-success", category: "Phase 6: Launch"),
      ev("wf-prod-deploy", d.(84), d.(84),
        color: "bg-success",
        icon: "🚀",
        category: "Phase 6: Launch"
      ),
      ev("wf-post-launch", d.(84), d.(95), color: "bg-success", category: "Phase 6: Launch"),
      ev("wf-launch", d.(95), d.(95),
        color: "bg-success",
        icon: "🎉",
        category: "Phase 6: Launch"
      ),

      # Phase 7: full-sized CRM connector sub-project (depth 2 nested)
      ev("wf-crm-connector", d.(38), nil,
        color: "bg-info",
        category: "Phase 7: Custom CRM connector"
      ),
      ev("wf-crm-discovery", d.(38), d.(42),
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-connector"}
      ),
      ev("wf-crm-api-spec", d.(42), d.(46),
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-connector"}
      ),
      ev("wf-crm-backend", d.(46), nil,
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-connector"}
      ),
      ev("wf-crm-be-auth", d.(46), d.(50),
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-backend"}
      ),
      ev("wf-crm-be-sync", d.(49), d.(56),
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-backend"}
      ),
      ev("wf-crm-be-mapping", d.(52), d.(59),
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-backend"}
      ),
      ev("wf-crm-be-error", d.(56), d.(62),
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-backend"}
      ),
      ev("wf-crm-frontend", d.(58), nil,
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-connector"}
      ),
      ev("wf-crm-fe-config", d.(58), d.(62),
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-frontend"}
      ),
      ev("wf-crm-fe-dashboard", d.(60), d.(67),
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-frontend"}
      ),
      ev("wf-crm-fe-history", d.(63), d.(70),
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-frontend"}
      ),
      ev("wf-crm-qa", d.(70), d.(75),
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-connector"}
      ),
      ev("wf-crm-rollout", d.(74), d.(78),
        color: "bg-info",
        category: "Phase 7: Custom CRM connector",
        extra: %{parent_id: "wf-crm-connector"}
      )
    ]
  end

  defp full_demo_connectors do
    [
      # Phase 1
      %{from: "wf-stakeholders", to: "wf-discovery-readout"},
      %{from: "wf-market-research", to: "wf-discovery-readout", critical: true},
      %{from: "wf-competitive", to: "wf-discovery-readout"},
      %{from: "wf-personas", to: "wf-discovery-readout"},
      %{from: "wf-discovery-readout", to: "wf-discovery-signoff", critical: true},
      # Phase 1 → Phase 2
      %{from: "wf-discovery-signoff", to: "wf-ia", critical: true},
      %{from: "wf-discovery-signoff", to: "wf-design-system"},
      %{from: "wf-ds-foundation", to: "wf-ds-components", critical: true},
      %{from: "wf-ds-components", to: "wf-ds-docs"},
      %{from: "wf-ds-comp-primitives", to: "wf-ds-comp-overlays"},
      %{from: "wf-ds-comp-overlays", to: "wf-ds-comp-data"},
      %{from: "wf-perf-baseline", to: "wf-perf-tuning", critical: true},
      %{from: "wf-perf-tuning", to: "wf-perf-monitoring"},
      # Phase 2
      %{from: "wf-ia", to: "wf-design-system", type: :ss, label: "parallel"},
      %{from: "wf-ia", to: "wf-wf-landing"},
      %{from: "wf-ia", to: "wf-wf-dashboard", critical: true},
      %{from: "wf-ia", to: "wf-wf-settings"},
      %{from: "wf-wf-landing", to: "wf-desktop-mockups"},
      %{from: "wf-wf-dashboard", to: "wf-mobile-mockups", critical: true},
      %{from: "wf-wf-dashboard", to: "wf-desktop-mockups"},
      %{from: "wf-wf-settings", to: "wf-desktop-mockups"},
      %{from: "wf-design-system", to: "wf-design-qa"},
      %{from: "wf-mobile-mockups", to: "wf-design-qa", critical: true},
      %{from: "wf-desktop-mockups", to: "wf-design-qa"},
      %{from: "wf-design-qa", to: "wf-design-signoff", critical: true},
      # Phase 2 → Phase 3
      %{from: "wf-design-signoff", to: "wf-db-schema", critical: true},
      # Phase 2 → Phase 4
      %{from: "wf-design-signoff", to: "wf-component-library", critical: true},
      # Phase 3
      %{from: "wf-db-schema", to: "wf-db-migrations", critical: true},
      %{from: "wf-db-schema", to: "wf-auth-service"},
      %{from: "wf-db-schema", to: "wf-search-api"},
      %{from: "wf-db-migrations", to: "wf-user-api", critical: true},
      %{from: "wf-db-migrations", to: "wf-settings-api"},
      %{from: "wf-auth-service", to: "wf-user-api", critical: true},
      %{from: "wf-auth-service", to: "wf-notification-service", type: :ss, label: "parallel"},
      %{from: "wf-user-api", to: "wf-payment-integration", critical: true},
      %{from: "wf-user-api", to: "wf-reporting-api"},
      %{from: "wf-user-api", to: "wf-backend-integration", type: :ff},
      %{from: "wf-settings-api", to: "wf-backend-integration", type: :ff},
      %{from: "wf-search-api", to: "wf-backend-integration", type: :ff},
      %{from: "wf-backend-integration", to: "wf-backend-freeze", critical: true},
      %{from: "wf-payment-integration", to: "wf-backend-freeze", label: "must complete"},
      %{from: "wf-notification-service", to: "wf-backend-freeze"},
      %{from: "wf-reporting-api", to: "wf-backend-freeze"},
      # Phase 3 → Phase 4 (cross-group API → UI)
      %{from: "wf-design-signoff", to: "wf-fe-scaffold"},
      %{from: "wf-auth-service", to: "wf-auth-flows"},
      %{from: "wf-user-api", to: "wf-dashboard"},
      %{from: "wf-settings-api", to: "wf-settings-page"},
      %{from: "wf-search-api", to: "wf-search-ui"},
      %{from: "wf-payment-integration", to: "wf-payment-ui", critical: true},
      %{from: "wf-reporting-api", to: "wf-reports-ui"},
      # Phase 4 (component-library 7-way fan-out + frontend-qa 7-way :ff fan-in)
      %{from: "wf-component-library", to: "wf-auth-flows", critical: true},
      %{from: "wf-component-library", to: "wf-landing-page"},
      %{from: "wf-component-library", to: "wf-dashboard"},
      %{from: "wf-component-library", to: "wf-settings-page"},
      %{from: "wf-component-library", to: "wf-search-ui"},
      %{from: "wf-component-library", to: "wf-payment-ui", critical: true},
      %{from: "wf-component-library", to: "wf-reports-ui"},
      %{from: "wf-landing-page", to: "wf-frontend-qa", type: :ff},
      %{from: "wf-dashboard", to: "wf-frontend-qa", type: :ff, critical: true},
      %{from: "wf-settings-page", to: "wf-frontend-qa", type: :ff},
      %{from: "wf-search-ui", to: "wf-frontend-qa", type: :ff},
      %{from: "wf-payment-ui", to: "wf-frontend-qa", type: :ff, critical: true},
      %{from: "wf-reports-ui", to: "wf-frontend-qa", type: :ff},
      %{from: "wf-auth-flows", to: "wf-frontend-qa", type: :ff},
      %{from: "wf-frontend-qa", to: "wf-frontend-freeze", critical: true},
      # Phase 4 + 3 → Phase 5
      %{from: "wf-frontend-freeze", to: "wf-cross-team", critical: true},
      %{from: "wf-backend-freeze", to: "wf-cross-team"},
      # Phase 5
      %{from: "wf-cross-team", to: "wf-performance", critical: true},
      %{from: "wf-cross-team", to: "wf-security-audit", type: :ss, label: "parallel"},
      %{from: "wf-performance", to: "wf-load-testing", label: "must finish first"},
      %{from: "wf-load-testing", to: "wf-bug-bash"},
      %{from: "wf-security-audit", to: "wf-bug-bash"},
      %{from: "wf-bug-bash", to: "wf-preprod", critical: true},
      # Phase 6
      %{from: "wf-backend-freeze", to: "wf-documentation", type: :ff},
      %{from: "wf-frontend-freeze", to: "wf-legal-review"},
      %{from: "wf-preprod", to: "wf-beta-rollout", critical: true},
      %{from: "wf-beta-rollout", to: "wf-prod-deploy", critical: true, label: "go/no-go"},
      %{from: "wf-prod-deploy", to: "wf-post-launch", type: :ss, label: "parallel"},
      %{from: "wf-prod-deploy", to: "wf-launch", critical: true},
      %{from: "wf-documentation", to: "wf-launch", label: "publish"},
      %{from: "wf-marketing", to: "wf-launch"},

      # Phase 7 internal chain
      %{from: "wf-crm-discovery", to: "wf-crm-api-spec", critical: true},
      %{from: "wf-crm-api-spec", to: "wf-crm-backend", critical: true},
      %{from: "wf-crm-api-spec", to: "wf-crm-frontend"},
      %{from: "wf-crm-be-auth", to: "wf-crm-be-sync", critical: true},
      %{from: "wf-crm-be-auth", to: "wf-crm-be-mapping"},
      %{from: "wf-crm-be-sync", to: "wf-crm-be-error", critical: true},
      %{from: "wf-crm-be-mapping", to: "wf-crm-be-error"},
      %{from: "wf-crm-fe-config", to: "wf-crm-fe-dashboard"},
      %{from: "wf-crm-fe-config", to: "wf-crm-fe-history"},
      %{from: "wf-crm-fe-dashboard", to: "wf-crm-fe-history", type: :ff},
      %{from: "wf-crm-backend", to: "wf-crm-qa", critical: true},
      %{from: "wf-crm-frontend", to: "wf-crm-qa", critical: true},
      %{from: "wf-crm-qa", to: "wf-crm-rollout", critical: true},
      %{from: "wf-discovery-signoff", to: "wf-crm-discovery"},
      %{from: "wf-auth-service", to: "wf-crm-be-auth", type: :ff, label: "auth ready"},
      %{from: "wf-crm-rollout", to: "wf-launch", label: "must complete"},
      # Intentional conflicts (broken schedules — render as red dashed)
      %{from: "wf-prod-deploy", to: "wf-marketing", label: "conflict"},
      %{from: "wf-documentation", to: "wf-legal-review", label: "blocked"}
    ]
  end

  # -- Render + dump --

  defp dump(name, {events, connectors, today}, opts) do
    zoom = opts |> Keyword.get(:zoom, "week") |> String.to_atom()
    stagger = Keyword.get(opts, :stagger, 0)
    expanded = parse_expanded_opt(opts) |> resolve_expanded(events)

    range = derive_range(events)

    render_opts = %{
      events: events,
      date_range: range,
      connectors: connectors,
      zoom: zoom,
      today: today,
      bus_stagger_outgoing_px: stagger,
      bus_stagger_incoming_px: stagger,
      expanded: expanded
    }

    html = render(render_opts)
    geom = Inspector.inspect_html(html)

    Mix.shell().info("""

    ╔══════════════════════════════════════════════════
    ║ PhoenixLiveGantt fixture: #{name}
    ║ zoom=#{zoom}  stagger=#{stagger}  range=#{range.first}..#{range.last}
    ║ expanded=#{format_expanded(expanded)}
    ╚══════════════════════════════════════════════════
    """)

    print_rows(geom)
    print_subproject_tree(geom)
    print_connectors(geom)
    print_edges(geom)
    print_audit(html)

    if Keyword.get(opts, :raw, false) do
      Mix.shell().info("\n=== Raw HTML ===\n#{html}")
    end
  end

  # `--expanded a,b,c` → MapSet.new(["a", "b", "c"])
  # `--expanded *`     → expand-all sentinel; expand every sub-project
  #                     visible in the rendered output.
  defp parse_expanded_opt(opts) do
    case Keyword.get(opts, :expanded) do
      nil -> MapSet.new()
      "*" -> :all
      str -> str |> String.split(",", trim: true) |> MapSet.new()
    end
  end

  defp format_expanded(set) do
    case MapSet.size(set) do
      0 -> "(none — all sub-projects collapsed)"
      n when n > 8 -> "#{n} sub-projects"
      _ -> set |> Enum.sort() |> Enum.join(",")
    end
  end

  # `--expanded *` → all sub-projects (any event whose id is referenced
  # as another event's `extra.parent_id`).
  defp resolve_expanded(:all, events) do
    events
    |> Enum.flat_map(fn ev ->
      case ev do
        %{extra: %{parent_id: pid}} when is_binary(pid) -> [pid]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp resolve_expanded(set, _events), do: set

  # Run the same geometry assertions used in tests against the rendered
  # html. The user has burned us before by missing piercings here that
  # only showed up in the live demo — running the full audit on every
  # dump catches that without us having to remember.
  defp print_audit(html) do
    issues = TestHelpers.find_geometry_issues(html)

    Mix.shell().info("\n=== Geometry audit ===")

    case issues do
      [] ->
        Mix.shell().info("  ✓ no issues found")

      _ ->
        Mix.shell().info("  ✗ #{length(issues)} issue group(s):")

        Enum.each(issues, fn {name, msg} ->
          Mix.shell().info("    [#{name}]")

          msg
          |> String.split("\n")
          |> Enum.each(fn line -> Mix.shell().info("      #{line}") end)
        end)
    end
  end

  # Render via the component-call syntax so attr defaults are injected
  # by Phoenix.Component's macro. Without this we'd have to maintain a
  # full default-assigns map matching every PhoenixLiveGantt attr.
  defp render(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"<PhoenixLiveGantt.gantt {@attrs} />")
  end

  defp derive_range(events) do
    dates =
      events
      |> Enum.flat_map(fn e ->
        [
          to_date(e.start),
          to_date(PhoenixLiveGantt.Task.effective_end(e))
        ]
      end)

    first = Enum.min(dates, Date) |> Date.add(-1)
    last = Enum.max(dates, Date) |> Date.add(1)
    Date.range(first, last)
  end

  defp to_date(%Date{} = d), do: d
  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)

  defp print_rows(geom) do
    Mix.shell().info("=== Rows (top → bottom) ===")

    Enum.each(Enum.with_index(geom.rows), fn {id, i} ->
      bar = Map.get(geom.bars, id, %{})
      Mix.shell().info("  #{String.pad_leading("#{i}", 2)}: #{id}#{format_bar(bar)}")
    end)
  end

  # Shows the sub-project tree as derived from the rendered HTML's
  # `data-parent-id` attributes — useful for confirming that the
  # parent/child wiring made it through the renderer correctly, and
  # to surface where the sub-project frames landed (only present
  # when sub-projects are expanded).
  defp print_subproject_tree(geom) do
    if geom.parent_map == %{} and geom.subproject_frames == [] do
      :ok
    else
      Mix.shell().info("\n=== Sub-projects ===")

      roots =
        geom.rows
        |> Enum.filter(fn id ->
          # A "root" here = an event in the tree (parent or child of
          # something) whose own parent isn't visible in this render.
          (Inspector.subproject?(geom, id) or Map.has_key?(geom.parent_map, id)) and
            is_nil(Map.get(geom.parent_map, id))
        end)

      Enum.each(roots, &print_subproject_node(geom, &1, 0))

      if geom.subproject_frames != [] do
        Mix.shell().info("  -- Frames (only present for EXPANDED sub-projects) --")

        Enum.each(geom.subproject_frames, fn f ->
          Mix.shell().info(
            "    rect x=#{f.left_px}..#{f.left_px + f.width} y=#{f.top_y}..#{f.top_y + f.height}  bg=#{f.background_color}"
          )
        end)
      end
    end
  end

  defp print_subproject_node(geom, id, depth) do
    children = Inspector.children_of(geom, id)
    marker = if children == [], do: "•", else: "▾"
    pad = String.duplicate("  ", depth + 1)
    Mix.shell().info("#{pad}#{marker} #{id}")
    Enum.each(children, &print_subproject_node(geom, &1, depth + 1))
  end

  defp print_connectors(geom) do
    Mix.shell().info("\n=== Connectors (#{length(geom.connectors)}) ===")

    Enum.each(geom.connectors, fn c ->
      flags =
        [{c.critical, "critical"}, {c.invalid, "INVALID"}]
        |> Enum.filter(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      flag_str = if flags == [], do: "", else: " [#{Enum.join(flags, ", ")}]"
      Mix.shell().info("  #{c.from} → #{c.to} (#{c.type})#{flag_str}")
      Mix.shell().info("    #{format_segments(c.segments)}")
    end)
  end

  defp print_edges(%{edges: %{earlier: 0, later: 0}}), do: :ok

  defp print_edges(geom) do
    Mix.shell().info("\n=== Edge indicators ===")
    Mix.shell().info("  ← #{geom.edges.earlier} earlier   #{geom.edges.later} later →")
  end

  defp format_bar(%{kind: :bar, left: l, width: w}),
    do: "  bar @ x=#{l}..#{l + w} (#{w}px wide)"

  defp format_bar(%{kind: :milestone, left: l}), do: "  ◆ milestone @ x=#{l}"
  defp format_bar(_), do: ""

  defp format_segments(%{kind: :forward, x1: x1, y1: y1, mid: mid, y2: y2, arrow_stop: stop}),
    do: "forward: src=(#{x1},#{y1}) → mid=#{mid} → tgt=(#{stop},#{y2})"

  defp format_segments(%{
         kind: :detour,
         x1: x1,
         y1: y1,
         stem_out: so,
         detour_y: dy,
         stem_in: si,
         y2: y2,
         arrow_stop: stop
       }),
       do:
         "detour:  src=(#{x1},#{y1}) → stem_out=#{so} → detour_y=#{dy} → stem_in=#{si} → tgt=(#{stop},#{y2})"

  defp format_segments(%{kind: :unknown, raw: r}), do: "unknown: #{r}"
end
