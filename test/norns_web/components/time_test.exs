defmodule NornsWeb.TimeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  test "renders UTC with an ISO datetime for the LocalTime hook" do
    html = render_component(&NornsWeb.Time.local_time/1, id: "t", at: ~U[2026-10-04 14:03:22.045123Z])

    assert html =~ ~s(datetime="2026-10-04T14:03:22.045123Z")
    assert html =~ ~s(phx-hook="LocalTime")
    assert html =~ "2026-10-04 14:03:22 UTC"
  end

  test "time format keeps zero-padded milliseconds" do
    html = render_component(&NornsWeb.Time.local_time/1, id: "t", at: ~U[2026-10-04 14:03:22.045123Z], format: "time")

    assert html =~ "14:03:22.045 UTC"
  end

  test "treats naive datetimes as UTC" do
    html = render_component(&NornsWeb.Time.local_time/1, id: "t", at: ~N[2026-10-04 14:03:22])

    assert html =~ ~s(datetime="2026-10-04T14:03:22Z")
  end
end
