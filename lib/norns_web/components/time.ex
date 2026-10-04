defmodule NornsWeb.Time do
  @moduledoc """
  Timestamps rendered in the viewer's timezone and locale.

  The server renders UTC; the `LocalTime` hook in the root layout rewrites the
  text with `Intl.DateTimeFormat` once the page connects. Hovering shows UTC.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :at, :any, required: true, doc: "a DateTime or NaiveDateTime (assumed UTC)"
  attr :format, :string, default: "datetime", values: ~w(datetime time)
  attr :class, :any, default: nil

  def local_time(%{at: nil} = assigns), do: ~H""

  def local_time(assigns) do
    assigns = assign(assigns, :utc, to_utc(assigns.at))

    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@utc)}
      title={Calendar.strftime(@utc, "%Y-%m-%d %H:%M:%S UTC")}
      data-format={@format}
      phx-hook="LocalTime"
      phx-update="ignore"
      class={@class}
    ><%= fallback(@utc, @format) %></time>
    """
  end

  defp to_utc(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")
  defp to_utc(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")

  defp fallback(dt, "time"),
    do: Calendar.strftime(dt, "%H:%M:%S.") <> pad_ms(dt) <> " UTC"

  defp fallback(dt, "datetime"), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp pad_ms(%{microsecond: {us, _}}),
    do: us |> div(1000) |> Integer.to_string() |> String.pad_leading(3, "0")
end
