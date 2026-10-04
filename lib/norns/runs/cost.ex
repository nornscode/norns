defmodule Norns.Runs.Cost do
  @moduledoc """
  What a run's LLM calls cost, in US dollars.

  Every `llm_response` and `context_compacted` event carries the model that
  served the call and its token counts. Tokens are facts; prices change, so
  dollars are computed when read, never stored.

  `input_tokens` counts cache reads and writes too; each is priced at its own
  rate. Cache writes are priced at the 5-minute rate (1.25x input) — the
  usage report does not say which TTL a write used, and 1-hour writes cost
  2x. Long-context tiers are not modelled.

  Prices are USD per million tokens, Anthropic first-party API rates as of
  2026-09-25. Bedrock and Vertex bill their own rates. Operators can add or
  override models:

      config :norns, Norns.Runs.Cost,
        prices: %{"gpt-5" => %{input: "1.25", output: "10", cache_read: "0.125", cache_write: "1.25"}}

  A model with no price is reported as unpriced, never as free.
  """

  @prices %{
    "claude-fable-5-1" => %{input: "10", output: "50", cache_read: "0.25"},
    "claude-mythos-5-1" => %{input: "10", output: "50", cache_read: "0.25"},
    "claude-fable-5" => %{input: "10", output: "50", cache_read: "1"},
    "claude-mythos-5" => %{input: "10", output: "50", cache_read: "1"},
    "claude-opus-5-5" => %{input: "4", output: "20", cache_read: "0.20"},
    "claude-opus-5" => %{input: "5", output: "25", cache_read: "0.50"},
    "claude-opus-4-8" => %{input: "5", output: "25", cache_read: "0.50"},
    "claude-opus-4-7" => %{input: "5", output: "25", cache_read: "0.50"},
    "claude-opus-4-6" => %{input: "5", output: "25", cache_read: "0.50"},
    "claude-sonnet-5-5" => %{input: "2", output: "10", cache_read: "0.20"},
    "claude-sonnet-5" => %{input: "2", output: "10", cache_read: "0.20"},
    "claude-sonnet-4-6" => %{input: "3", output: "15", cache_read: "0.30"},
    "claude-haiku-4-5" => %{input: "1", output: "5", cache_read: "0.10"}
  }

  @million Decimal.new(1_000_000)

  @doc """
  Price a list of `{model, usage}` pairs, one per LLM call or already summed
  per model. Returns the dollars for the priced calls and the token counts
  of the ones no price covers.
  """
  def of_usages(pairs) do
    pairs
    |> Enum.group_by(fn {model, _} -> model end, fn {_, usage} -> usage end)
    |> Enum.reduce(%{usd: Decimal.new(0), unpriced: []}, fn {model, usages}, acc ->
      usage = sum(usages)

      case price(model) do
        nil ->
          entry = %{model: model, input_tokens: usage.input, output_tokens: usage.output}
          %{acc | unpriced: [entry | acc.unpriced]}

        price ->
          %{acc | usd: Decimal.add(acc.usd, dollars(usage, price))}
      end
    end)
    |> then(fn acc -> %{acc | usd: Decimal.round(acc.usd, 6), unpriced: Enum.sort_by(acc.unpriced, &(&1.model || ""))} end)
  end

  @doc """
  The price of a model, or nil. Matches provider spellings of a known id:
  `anthropic/claude-sonnet-5`, `anthropic:claude-sonnet-5`,
  `claude-sonnet-5-20260801`, `us.anthropic.claude-sonnet-5-v1:0`,
  `claude-sonnet-5@20260801`. The longest matching id wins, so
  `claude-sonnet-5-5` is never priced as `claude-sonnet-5`, and an id the
  table does not know is not priced as an older one.
  """
  def price(model) when is_binary(model) do
    model = String.downcase(model)

    prices()
    |> Enum.filter(fn {id, _} -> matches?(model, id) end)
    |> Enum.max_by(fn {id, _} -> String.length(id) end, fn -> nil end)
    |> case do
      nil -> nil
      {_id, price} -> price
    end
  end

  def price(_model), do: nil

  defp matches?(model, id) do
    # A provider prefix before the id; an optional date, then the end, a
    # version (`@`, `:`, `-v1`) after it.
    Regex.match?(~r/(?:^|[\/:.])#{Regex.escape(id)}(?:-\d{8})?(?:$|@|:|-v\d)/, model)
  end

  defp prices do
    overrides = Application.get_env(:norns, __MODULE__, []) |> Keyword.get(:prices, %{})

    @prices
    |> Map.merge(overrides)
    |> Map.new(fn {id, p} -> {String.downcase(id), decimals(p)} end)
  end

  defp decimals(p) do
    p = Map.new(p, fn {k, v} -> {to_atom(k), v} end)
    input = dec(p.input)

    %{
      input: input,
      output: dec(p.output),
      cache_read: dec(Map.get(p, :cache_read, p.input)),
      cache_write: if(Map.has_key?(p, :cache_write), do: dec(p.cache_write), else: Decimal.mult(input, Decimal.new("1.25")))
    }
  end

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)

  defp dec(%Decimal{} = d), do: d
  defp dec(n) when is_binary(n), do: Decimal.new(n)
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(n) when is_float(n), do: Decimal.from_float(n)

  defp sum(usages) do
    Enum.reduce(usages, %{input: 0, output: 0, cache_read: 0, cache_write: 0}, fn u, acc ->
      %{
        input: acc.input + count(u, "input_tokens"),
        output: acc.output + count(u, "output_tokens"),
        cache_read: acc.cache_read + count(u, "cache_read_tokens"),
        cache_write: acc.cache_write + count(u, "cache_write_tokens")
      }
    end)
  end

  defp count(usage, key) do
    case usage[key] do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp dollars(usage, price) do
    plain = max(usage.input - usage.cache_read - usage.cache_write, 0)

    [
      {plain, price.input},
      {usage.cache_read, price.cache_read},
      {usage.cache_write, price.cache_write},
      {usage.output, price.output}
    ]
    |> Enum.reduce(Decimal.new(0), fn {tokens, rate}, acc -> Decimal.add(acc, Decimal.mult(tokens, rate)) end)
    |> Decimal.div(@million)
  end
end
