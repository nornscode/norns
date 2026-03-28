defmodule Norns.Tools.BehaviourTest do
  use ExUnit.Case, async: true

  alias Norns.Tools.WebSearch

  describe "use Norns.Tools.Behaviour" do
    test "WebSearch implements all callbacks" do
      assert WebSearch.name() == "web_search"
      assert is_binary(WebSearch.description())
      assert is_map(WebSearch.input_schema())
      assert {:ok, _} = WebSearch.execute(%{"query" => "test"})
    end

    test "__tool__/0 returns a valid Tool struct" do
      tool = WebSearch.__tool__()
      assert %Norns.Tools.Tool{} = tool
      assert tool.name == "web_search"
      assert is_function(tool.handler, 1)
    end

    test "to_api_format/0 returns API-compatible map" do
      api = WebSearch.to_api_format()
      assert api.name == "web_search"
      assert is_binary(api.description)
      assert is_map(api.parameters)
      refute Map.has_key?(api, :handler)
    end

    test "backward compat: tool/0 works" do
      assert WebSearch.tool() == WebSearch.__tool__()
    end
  end
end
