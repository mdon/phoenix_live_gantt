defmodule LiveGantt.Utils.Safe do
  @moduledoc false
  # Defensive helpers used by the renderer — input sanitisation, css
  # value validation, and the daisyUI text-color inference.

  require Logger

  @doc """
  Validates a CSS dimension value (e.g. `"3rem"`, `"48px"`, `"50%"`,
  `"5vh"`). Returns the value if safe, or a fallback if not.
  """
  def sanitize_css_dimension(value, fallback \\ "3rem")

  def sanitize_css_dimension(value, fallback) when is_binary(value) do
    if Regex.match?(~r/^\d+(\.\d+)?\s*(px|rem|em|vh|vw|%|ch|ex|vmin|vmax)$/, value) do
      value
    else
      Logger.warning("[LiveGantt] Invalid CSS dimension: #{inspect(value)}, using #{fallback}")
      fallback
    end
  end

  def sanitize_css_dimension(_, fallback), do: fallback

  @doc """
  Infers the daisyUI text content color from a background color class.

      "bg-warning"     -> "text-warning-content"
      "bg-primary/80"  -> "text-primary-content"
      nil              -> "text-primary-content"
      other            -> "text-base-content"
  """
  def infer_text_color(nil), do: "text-primary-content"

  def infer_text_color(bg_class) when is_binary(bg_class) do
    case Regex.run(
           ~r/bg-(primary|secondary|accent|neutral|info|success|warning|error)/,
           bg_class
         ) do
      [_, color] -> "text-#{color}-content"
      _ -> "text-base-content"
    end
  end
end
