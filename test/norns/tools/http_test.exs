defmodule Norns.Tools.HttpTest do
  use ExUnit.Case, async: true

  alias Norns.Tools.Http

  describe "behaviour" do
    test "implements all callbacks" do
      assert Http.name() == "http_request"
      assert is_binary(Http.description())
      assert is_map(Http.input_schema())
    end

    test "__tool__/0 returns valid Tool struct" do
      tool = Http.__tool__()
      assert tool.name == "http_request"
      assert is_function(tool.handler, 1)
    end
  end

  describe "execute/1" do
    @tag :external
    test "makes a GET request" do
      assert {:ok, response} = Http.execute(%{"url" => "https://httpbin.org/get"})
      assert response =~ "HTTP 200"
    end

    @tag :external
    test "defaults to GET when method not specified" do
      assert {:ok, response} = Http.execute(%{"url" => "https://httpbin.org/get"})
      assert response =~ "HTTP 200"
    end

    test "returns error for missing url" do
      assert {:error, _} = Http.execute(%{})
    end

    test "returns error for bad URL" do
      assert {:error, _} = Http.execute(%{"url" => "http://localhost:1"})
    end
  end
end
