defmodule Automaton.LLM do
  @moduledoc "Thin wrapper around the Anthropic Messages API."

  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @default_max_tokens 4096

  @doc """
  Send a completion request to the Anthropic API.

  Returns `{:ok, response_text}` or `{:error, reason}`.
  """
  def complete(api_key, model, system_prompt, user_message, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    body = %{
      model: model,
      max_tokens: max_tokens,
      system: system_prompt,
      messages: [%{role: "user", content: user_message}]
    }

    case Req.post(@api_url,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", @api_version},
             {"content-type", "application/json"}
           ],
           receive_timeout: 120_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        {:ok, text}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end
end
