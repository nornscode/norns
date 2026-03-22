defmodule Norns.LLMTest do
  use ExUnit.Case, async: true

  alias Norns.LLM
  alias Norns.LLM.Fake

  setup do
    Fake.set_responses([
      %{
        content: [%{"type" => "text", "text" => "Hello from fake LLM"}],
        stop_reason: "end_turn"
      }
    ])

    :ok
  end

  describe "chat/5" do
    test "returns structured response from fake" do
      assert {:ok, response} = LLM.chat("key", "model", "system", [%{role: "user", content: "hi"}])
      assert response.stop_reason == "end_turn"
      assert [%{"type" => "text", "text" => "Hello from fake LLM"}] = response.content
    end

    test "includes usage info" do
      {:ok, response} = LLM.chat("key", "model", "system", [%{role: "user", content: "hi"}])
      assert response.usage.input_tokens == 10
      assert response.usage.output_tokens == 20
    end
  end

  describe "complete/5 backward compat" do
    test "extracts text from chat response" do
      Fake.set_responses([
        %{
          content: [%{"type" => "text", "text" => "Completed text"}],
          stop_reason: "end_turn"
        }
      ])

      assert {:ok, "Completed text"} = LLM.complete("key", "model", "system", "prompt")
    end
  end

  describe "fake scripting" do
    test "consumes responses in order" do
      Fake.set_responses([
        %{content: [%{"type" => "text", "text" => "first"}], stop_reason: "end_turn"},
        %{content: [%{"type" => "text", "text" => "second"}], stop_reason: "end_turn"}
      ])

      {:ok, r1} = LLM.chat("k", "m", "s", [])
      {:ok, r2} = LLM.chat("k", "m", "s", [])

      assert [%{"text" => "first"}] = r1.content
      assert [%{"text" => "second"}] = r2.content
    end

    test "returns fallback when no responses left" do
      Fake.set_responses([])
      {:ok, response} = LLM.chat("k", "m", "s", [])
      assert response.stop_reason == "end_turn"
    end
  end
end
