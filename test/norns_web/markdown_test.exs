defmodule NornsWeb.MarkdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  defp render(text), do: text |> NornsWeb.Markdown.to_html() |> Phoenix.HTML.safe_to_string()

  defp scrub(html), do: HtmlSanitizeEx.Scrubber.scrub(html, NornsWeb.Markdown.Scrubber)

  describe "rendering" do
    test "headings, emphasis, lists, and code" do
      html = render("# Time\n\nCall `now` **first**.\n\n- one\n- two\n\n```\nx = 1\n```")

      assert html =~ "<h1>Time</h1>"
      assert html =~ "<code>now</code>"
      assert html =~ "<strong>first</strong>"
      assert html =~ "<li>one</li>"
      assert html =~ "<pre><code>x = 1"
    end

    test "single newlines become line breaks" do
      assert render("line one\nline two") =~ "<br"
    end

    test "nil renders as empty" do
      assert render(nil) == ""
    end

    test "http, https, and mailto links are kept" do
      assert render("[a](https://example.com)") =~ ~s(<a href="https://example.com">a</a>)
      assert render("[a](http://example.com)") =~ ~s(href="http://example.com")
      assert render("[a](mailto:x@example.com)") =~ ~s(href="mailto:x@example.com")
    end

    test "bare urls are linked" do
      assert render("see https://example.com now") =~ ~s(<a href="https://example.com">)
    end

    test "tables and strikethrough render" do
      html = render("| a | b |\n|---|---|\n| 1 | 2 |\n\n~~gone~~")
      assert html =~ "<table>"
      assert html =~ "<th>a</th>"
      assert html =~ "<del>gone</del>"
    end

    test "the component wraps output in a .markdown container" do
      html = render_component(&NornsWeb.Markdown.markdown/1, text: "hi", class: "x")

      assert html =~ ~s(<div class="markdown x"><p>hi</p>)
    end
  end

  describe "sanitizing markdown input" do
    test "raw html is dropped, surrounding text survives" do
      html = render("hello <script>alert(1)</script> world")
      refute html =~ "<script"
      assert html =~ "hello"
      assert html =~ "world"
    end

    test "html blocks are dropped" do
      html = render("text\n\n<script>alert(1)</script>\n\nmore")
      refute html =~ "<script"
      refute html =~ "alert"
      assert html =~ "more"
    end

    test "inline html with event handlers is dropped" do
      html = render(~s{before <i onmouseover="alert(1)">y</i> after})
      refute html =~ "onmouseover"
      assert html =~ "before"
      assert html =~ "after"
    end

    test "javascript: links are dropped in every spelling" do
      for url <- [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "  javascript:alert(1)",
            "vbscript:msgbox(1)",
            "data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg=="
          ] do
        html = render("[click](#{url})")
        refute html =~ ~r/href="[^"]*(javascript|vbscript|data)/i, "kept #{inspect(url)}: #{html}"
        assert html =~ "click"
      end
    end

    test "entity-encoded javascript: links are dropped" do
      html = render(~s{<a href="&#106;avascript:alert(1)">x</a>})
      refute html =~ "javascript"
      refute html =~ "href"
    end

    test "images are dropped" do
      html = render("![alt](https://example.com/pixel.gif) <img src=x onerror=alert(1)>")
      refute html =~ "<img"
      refute html =~ "onerror"
    end

    test "fenced code language classes are dropped" do
      html = render("```hidden\nx\n```")
      refute html =~ "class="
      assert html =~ "<pre><code>x"
    end

    test "code blocks keep their contents escaped" do
      html = render("```\n<script>alert(1)</script>\n```")
      refute html =~ "<script"
      assert html =~ "&lt;script&gt;"
    end

    test "html comments and cdata are dropped" do
      html = render("a <!-- hidden --> b <![CDATA[ <script>x</script> ]]> c")
      refute html =~ "hidden"
      refute html =~ "<script"
    end
  end

  # The scrubber is the second layer: it only sees markup MDEx generated, but
  # these pin down what it would do with raw HTML if that ever changed.
  describe "scrubber on raw html" do
    test "scripts, iframes, objects, forms, and styles are stripped" do
      html =
        scrub(
          ~s{<script>alert(1)</script><iframe src="https://evil"></iframe>} <>
            ~s{<object data="x"></object><form action="/x"><input name="a"></form>} <>
            ~s|<style>body{display:none}</style><p>ok</p>|
        )

      for tag <- ~w(script iframe object form input style) do
        refute html =~ "<#{tag}", "kept <#{tag}>: #{html}"
      end

      assert html =~ "<p>ok</p>"
    end

    test "event handlers, style, class, id, and phx bindings are stripped" do
      html =
        scrub(
          ~s{<b onclick="alert(1)">x</b><p style="position:fixed" class="hidden" id="phx-main">y</p>} <>
            ~s{<a href="https://x" phx-click="delete" title="t">z</a><div phx-hook="H">w</div>}
        )

      for attr <- ~w(onclick style= class= id= phx-) do
        refute html =~ attr, "kept #{attr}: #{html}"
      end

      assert html =~ "<b>x</b><p>y</p>"
      assert html =~ ~s(<a href="https://x" title="t">z</a>)
    end

    test "unsafe link schemes are stripped" do
      for url <- ["javascript:alert(1)", "JaVaScRiPt:alert(1)", "data:text/html,x", "vbscript:x"] do
        html = scrub(~s{<a href="#{url}">x</a>})
        refute html =~ "href", "kept #{inspect(url)}: #{html}"
      end

      assert scrub(~s{<a href="https://ok">x</a>}) =~ ~s(href="https://ok")
    end

    test "images are stripped" do
      refute scrub(~s{<img src="https://x/pixel.gif" onerror="alert(1)">}) =~ "<img"
    end
  end
end
