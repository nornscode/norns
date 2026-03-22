defmodule Norns.Tools.WebSearch do
  @moduledoc "Demo web search tool. Returns a stub result for now."

  alias Norns.Tools.Tool

  def tool do
    %Tool{
      name: "web_search",
      description: "Search the web for information. Returns a summary of search results.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "The search query"
          }
        },
        "required" => ["query"]
      },
      handler: &search/1
    }
  end

  def search(%{"query" => query}) do
    {:ok, "Search results for '#{query}': This is a stub result. No actual web search was performed."}
  end

  def search(_), do: {:error, "Missing required parameter: query"}
end
