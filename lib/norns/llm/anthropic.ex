defmodule Norns.LLM.Anthropic do
  @moduledoc "Anthropic Messages API implementation."

  @behaviour Norns.LLM.Behaviour

  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @default_max_tokens 4096

  @impl true
  def chat(api_key, model, system_prompt, messages, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    tools = Keyword.get(opts, :tools, [])

    body =
      %{
        model: model,
        max_tokens: max_tokens,
        system: system_prompt,
        messages: messages
      }
      |> maybe_add_tools(tools)

    case Req.post(@api_url,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", @api_version},
             {"content-type", "application/json"}
           ],
           receive_timeout: 120_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools), do: Map.put(body, :tools, tools)

  defp parse_response(body) do
    %{
      content: body["content"] || [],
      stop_reason: body["stop_reason"],
      usage: %{
        input_tokens: get_in(body, ["usage", "input_tokens"]) || 0,
        output_tokens: get_in(body, ["usage", "output_tokens"]) || 0
      }
    }
  end
end
