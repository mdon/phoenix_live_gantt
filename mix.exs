defmodule PhoenixLiveGantt.MixProject do
  use Mix.Project

  @version "0.2.0"
  @description "Phoenix LiveView Gantt chart with dependency arrows, sub-projects, and click-to-detail popovers"
  @source_url "https://github.com/mdon/phoenix_live_gantt"

  def project do
    [
      app: :phoenix_live_gantt,
      version: @version,
      description: @description,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      name: "PhoenixLiveGantt",
      source_url: @source_url
    ]
  end

  defp aliases do
    [
      precommit: [
        "format",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "test"
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Run the whole `precommit` alias in :test (so its `mix test` step is happy and
  # `credo`, which is in [:dev, :test], stays available).
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix, "~> 1.7"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      name: "phoenix_live_gantt",
      maintainers: ["mdon"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "PhoenixLiveGantt",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
