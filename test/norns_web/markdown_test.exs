defmodule NornsWeb.MarkdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  defp render(text), do: text |> NornsWeb.Markdown.to_html() |> Phoenix.HTML.safe_to_string()

  describe "rendering" do
    test "headings, emphasis, lists, and code" do
      html = render("# Time\n\nCall `now` **first**.\n\n- one\n- two\n\n```\nx = 1\n```")

      assert html =~ "<h1>Time</h1>"
      assert html =~ "<code class=\"inline\">now</code>" or html =~ "<code>now</code>"
      assert html =~ "<strong>first</strong>"
      assert html =~ "<li>one</li>"
      assert html =~ "<pre><code>x = 1</code></pre>"
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

    test "the component wraps output in a .markdown container" do
      html = render_component(&NornsWeb.Markdown.markdown/1, text: "hi", class: "x")

      assert html =~ ~s(<div class="markdown x"><p>hi</p>)
    end
  end

  describe "sanitizing" do
    test "script tags are dropped" do
      html = render("hello <script>alert(1)</script> world")
      refute html =~ "<script"
      assert html =~ "hello"
    end

    test "fenced html blocks are dropped" do
      html = render("text\n\n<script>alert(1)</script>\n\nmore")
      refute html =~ "<script"
    end

    test "event handler attributes are dropped" do
      html = render(~s{<b onclick="alert(1)">x</b>})
      refute html =~ "onclick"
      assert html =~ "<b>x</b>"
    end

    test "inline html inside a sentence is shown literally" do
      html = render(~s{before <i onmouseover="alert(1)">y</i> after})
      refute html =~ ~r/<[^>]*onmouseover/
      assert html =~ "before &lt;i onmouseover"
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
        refute html =~ "javascript", "kept #{inspect(url)}: #{html}"
        refute html =~ "vbscript", "kept #{inspect(url)}: #{html}"
        refute html =~ "data:", "kept #{inspect(url)}: #{html}"
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
      refute html =~ ~r/<[^>]*onerror/
    end

    test "iframes, objects, forms, and styles are dropped" do
      html =
        render(
          ~s(<iframe src="https://evil"></iframe><object data="x"></object>) <>
            ~s(<form action="/x"><input name="a"></form><style>body{display:none}</style>)
        )

      refute html =~ "<iframe"
      refute html =~ "<object"
      refute html =~ "<form"
      refute html =~ "<input"
      refute html =~ "<style"
    end

    test "style, class, and id attributes are dropped" do
      html = render(~s(<p style="position:fixed" class="hidden" id="phx-main">x</p>))
      refute html =~ "style="
      refute html =~ "class="
      refute html =~ "id="
      assert html =~ "<p>x</p>"
    end

    test "fenced code language classes are dropped" do
      html = render("```hidden\nx\n```")
      refute html =~ "class="
      assert html =~ "<pre><code>x</code></pre>"
    end

    test "phoenix bindings are dropped" do
      html = render(~s(<a href="https://x" phx-click="delete">x</a><div phx-hook="H">y</div>))
      refute html =~ "phx-"
      assert html =~ ~s(<a href="https://x">x</a>)
    end

    test "html comments and cdata are dropped" do
      html = render("a <!-- hidden --> b <![CDATA[ <script>x</script> ]]> c")
      refute html =~ "hidden"
      refute html =~ "<script"
    end

    test "code blocks keep their contents escaped" do
      html = render("```\n<script>alert(1)</script>\n```")
      refute html =~ "<script"
      assert html =~ "&lt;script&gt;"
    end
  end
end
