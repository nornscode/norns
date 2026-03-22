defmodule Norns.Tools.WebSearch do
  @moduledoc "Web search tool via DuckDuckGo HTML search."

  use Norns.Tools.Behaviour

  @search_url "https://html.duckduckgo.com/html/"
  @max_results 5

  @impl true
  def name, do: "web_search"

  @impl true
  def description, do: "Search the web for information. Returns titles, URLs, and snippets from search results."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "The search query"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query}) do
    case Req.post(@search_url,
           form: [q: query],
           headers: [{"user-agent", "Norns/1.0 (Research Agent)"}],
           receive_timeout: 15_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        results = parse_results(body)

        if results == [] do
          {:ok, "No results found for '#{query}'."}
        else
          formatted =
            results
            |> Enum.with_index(1)
            |> Enum.map_join("\n\n", fn {r, i} ->
              "#{i}. #{r.title}\n   #{r.url}\n   #{r.snippet}"
            end)

          {:ok, "Search results for '#{query}':\n\n#{formatted}"}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "Search returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "Search failed: #{inspect(reason)}"}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: query"}

  defp parse_results(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(".result")
    |> Enum.take(@max_results)
    |> Enum.map(fn result ->
      title =
        result
        |> Floki.find(".result__a")
        |> Floki.text()
        |> String.trim()

      url =
        result
        |> Floki.find(".result__a")
        |> Floki.attribute("href")
        |> List.first("")
        |> extract_url()

      snippet =
        result
        |> Floki.find(".result__snippet")
        |> Floki.text()
        |> String.trim()

      %{title: title, url: url, snippet: snippet}
    end)
    |> Enum.reject(fn r -> r.title == "" end)
  end

  # DDG wraps URLs in a redirect — extract the actual URL
  defp extract_url("//duckduckgo.com/l/?uddg=" <> rest) do
    rest
    |> String.split("&", parts: 2)
    |> List.first("")
    |> URI.decode()
  end

  defp extract_url(url), do: url

  # Backward compat
  def tool, do: __tool__()
end
