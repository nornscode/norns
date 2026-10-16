defmodule NornsWeb.Markdown do
  @moduledoc """
  Renders markdown written by users and models as sanitized HTML.

  Prompts, replies, and run output are untrusted: a model can be prompt-injected
  into emitting HTML, and a user can paste anything. Every string goes through
  Earmark and then `NornsWeb.Markdown.Scrubber`, a strict allowlist: a small set
  of block and inline tags, links only to http, https, or mailto, no images, no
  inline event handlers, no styles, no classes. Anything else is stripped down to
  its text.
  """
  use Phoenix.Component

  alias HtmlSanitizeEx.Scrubber

  attr :text, :string, required: true
  attr :class, :any, default: nil

  @doc "Renders `text` as markdown inside a `.markdown` container."
  def markdown(assigns) do
    ~H"""
    <div class={["markdown", @class]}><%= to_html(@text) %></div>
    """
  end

  @doc "Converts markdown to a `Phoenix.HTML.safe` of sanitized HTML."
  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: Phoenix.HTML.raw("")

  def to_html(text) when is_binary(text) do
    html =
      case Earmark.as_html(text, earmark_options()) do
        {:ok, html, _messages} -> html
        {:error, html, _messages} -> html
      end

    html
    |> Scrubber.scrub(NornsWeb.Markdown.Scrubber)
    |> Phoenix.HTML.raw()
  end

  defp earmark_options do
    %Earmark.Options{
      gfm: true,
      breaks: true,
      smartypants: false,
      pure_links: true,
      compact_output: true
    }
  end
end

defmodule NornsWeb.Markdown.Scrubber do
  @moduledoc false

  # `use HtmlSanitizeEx` installs the fallback that strips any tag or
  # attribute not allowed below, keeping only its text.
  use HtmlSanitizeEx

  @plain_tags ~w(p br strong em b i s del u h1 h2 h3 h4 h5 h6 ul li blockquote pre code hr
                 table thead tbody tr th td sup sub)

  remove_cdata_sections_before_scrub()
  strip_comments()

  allow_tag_with_uri_attributes("a", ["href"], ["http", "https", "mailto"])
  allow_tag_with_these_attributes("a", ["title"])
  allow_tag_with_these_attributes("ol", ["start"])

  for tag <- @plain_tags do
    allow_tag_with_these_attributes(tag, [])
  end
end
