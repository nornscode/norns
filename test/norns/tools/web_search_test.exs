defmodule Norns.Tools.WebSearchTest do
  use ExUnit.Case, async: true

  alias Norns.Tools.WebSearch

  describe "behaviour" do
    test "implements all callbacks" do
      assert WebSearch.name() == "web_search"
      assert is_binary(WebSearch.description())
      assert is_map(WebSearch.input_schema())
    end

    test "__tool__/0 returns valid Tool struct" do
      tool = WebSearch.__tool__()
      assert tool.name == "web_search"
      assert is_function(tool.handler, 1)
    end
  end

  describe "execute/1" do
    @tag :external
    test "returns real search results" do
      assert {:ok, result} = WebSearch.execute(%{"query" => "Elixir programming language"})
      assert result =~ "Search results for"
      assert result =~ "1."
    end

    test "returns error for missing query" do
      assert {:error, _} = WebSearch.execute(%{})
    end
  end
end
