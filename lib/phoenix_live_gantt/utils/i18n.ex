defmodule PhoenixLiveGantt.Utils.I18n do
  @moduledoc """
  Minimal translation helper for Gantt labels + month names.

  Consumers pass a `translations` map to override the English defaults
  for the labels the chart actually renders (toolbar buttons, sidebar
  header, edge indicators, etc.). Anything not overridden falls back
  to the default English string.

  ## Example

      translations = %{
        labels: %{today: "Aujourd'hui", task: "Tâche"},
        month_names_short: %{1 => "Janv", 2 => "Févr", ...}
      }

      I18n.label(:today, translations)
      #=> "Aujourd'hui"
  """

  @default_month_names_short %{
    1 => "Jan",
    2 => "Feb",
    3 => "Mar",
    4 => "Apr",
    5 => "May",
    6 => "Jun",
    7 => "Jul",
    8 => "Aug",
    9 => "Sep",
    10 => "Oct",
    11 => "Nov",
    12 => "Dec"
  }

  @default_labels %{
    today: "Today",
    month: "Month",
    week: "Week",
    day: "Day",
    hour: "Hour",
    min15: "15m",
    min5: "5m",
    task: "Task",
    ungrouped: "Ungrouped",
    prev: "Previous",
    next: "Next",
    earlier_tasks: "%{count} earlier",
    later_tasks: "%{count} later",
    details_for: "Details for %{title}",
    no_title: "(No title)",
    expand_subproject: "Expand sub-project",
    collapse_subproject: "Collapse sub-project",
    today_scroll_disabled: "Set enable_hooks + id (or on_scroll_today) to enable scroll-to-today"
  }

  @type translations :: %{
          optional(:month_names_short) => %{(1..12) => String.t()},
          optional(:labels) => %{atom() => String.t()}
        }

  @doc "Short month name (e.g. \"Apr\") for month number 1-12."
  @spec month_name_short(1..12, translations()) :: String.t()
  def month_name_short(month, translations \\ %{}) do
    get_in(translations, [:month_names_short, month]) || @default_month_names_short[month]
  end

  @doc """
  Look up a label string by atom key (`:today`, `:task`, etc.) and
  format `%{count}`-style placeholders against the bindings map.
  """
  @spec label(atom(), translations(), map()) :: String.t()
  def label(key, translations \\ %{}, bindings \\ %{}) do
    str = get_in(translations, [:labels, key]) || @default_labels[key] || Atom.to_string(key)
    interpolate(str, bindings)
  end

  defp interpolate(str, bindings) when map_size(bindings) == 0, do: str

  defp interpolate(str, bindings) do
    Enum.reduce(bindings, str, fn {k, v}, acc ->
      String.replace(acc, "%{#{k}}", to_string(v))
    end)
  end
end
