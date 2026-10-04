defmodule Norns.Runs.CostTest do
  use Norns.DataCase, async: false

  alias Norns.Runs
  alias Norns.Runs.Cost

  describe "price/1" do
    test "matches the spellings providers and SDKs use for a model" do
      sonnet = Cost.price("claude-sonnet-5")

      for spelling <- [
            "claude-sonnet-5",
            "anthropic/claude-sonnet-5",
            "anthropic:claude-sonnet-5",
            "claude-sonnet-5-20260801",
            "claude-sonnet-5@20260801",
            "us.anthropic.claude-sonnet-5-20260801-v1:0",
            "Claude-Sonnet-5"
          ] do
        assert Cost.price(spelling) == sonnet, spelling
      end
    end

    test "a newer id is never priced as the older one it starts with" do
      # Opus 5.5 is $4 in; Opus 5 is $5.
      assert Decimal.equal?(Cost.price("anthropic/claude-opus-5-5-20261001").input, Decimal.new(4))
      assert Decimal.equal?(Cost.price("claude-opus-5-20260101").input, Decimal.new(5))
      assert Cost.price("claude-opus-5-7") == nil
    end

    test "unknown and missing models have no price" do
      assert Cost.price("gpt-5") == nil
      assert Cost.price(nil) == nil
    end

    test "operators can add models, and a cache write defaults to 1.25x input" do
      Application.put_env(:norns, Cost, prices: %{"gpt-5" => %{input: "1.25", output: "10"}})
      on_exit(fn -> Application.delete_env(:norns, Cost) end)

      price = Cost.price("openai/gpt-5")
      assert Decimal.equal?(price.cache_write, Decimal.new("1.5625"))
      assert Decimal.equal?(price.cache_read, Decimal.new("1.25"))
    end
  end

  describe "of_usages/1" do
    test "prices plain input, cache reads, cache writes and output each at their rate" do
      # Opus 5.5: $4 in, $20 out, $0.20 cache read, $5 cache write (1.25x).
      usage = %{
        "input_tokens" => 1_000_000,
        "cache_read_tokens" => 600_000,
        "cache_write_tokens" => 200_000,
        "output_tokens" => 100_000
      }

      # 200k plain * 4 + 600k * 0.20 + 200k * 5 + 100k * 20, per million.
      assert %{usd: usd, unpriced: []} = Cost.of_usages([{"claude-opus-5-5", usage}])
      assert Decimal.equal?(usd, Decimal.new("3.92"))
    end

    test "sums calls per model and reports tokens no price covers instead of calling them free" do
      call = %{"input_tokens" => 1_000, "output_tokens" => 100}

      result = Cost.of_usages([{"claude-haiku-4-5", call}, {"claude-haiku-4-5", call}, {"gpt-5", call}, {nil, call}])

      assert Decimal.equal?(result.usd, Decimal.new("0.003"))
      assert result.unpriced == [
               %{model: nil, input_tokens: 1_000, output_tokens: 100},
               %{model: "gpt-5", input_tokens: 1_000, output_tokens: 100}
             ]
    end
  end

  describe "Runs.cost/1" do
    test "prices a run's LLM calls from its events, compaction included" do
      tenant = create_tenant()
      agent = create_agent(tenant)

      {:ok, run} =
        Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: "completed"})

      usage = %{"input_tokens" => 10_000, "output_tokens" => 1_000, "cache_read_tokens" => 8_000}

      for {type, extra} <- [
            {"llm_response", %{"content" => "a", "step" => 1}},
            {"llm_response", %{"content" => "b", "step" => 2}},
            {"context_compacted", %{"step" => 2, "dropped" => 1, "kept" => 1, "summary" => "s"}}
          ] do
        payload = Map.merge(extra, %{"usage" => usage, "model" => "claude-sonnet-5"})
        {:ok, _} = Runs.append_event(run, %{event_type: type, source: "system", payload: payload})
      end

      {:ok, _} =
        Runs.append_event(run, %{event_type: "llm_response", source: "system", payload: %{"content" => "c", "step" => 3, "usage" => usage}})

      # Per call: 2k plain * $2 + 8k * $0.20 + 1k * $10 = $0.0156, three priced calls.
      assert %{usd: usd, unpriced: [%{model: nil, input_tokens: 10_000, output_tokens: 1_000}]} = Runs.cost(run)
      assert Decimal.equal?(usd, Decimal.new("0.0468"))
    end
  end
end
