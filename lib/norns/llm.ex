defmodule Norns.LLM do
  @moduledoc """
  LLM dispatcher. Delegates to the configured backend module.

  Configure via:
    config :norns, Norns.LLM, module: Norns.LLM.Anthropic
  """

  @doc "Multi-turn chat with optional tool definitions."
  def chat(api_key, model, system_prompt, messages, opts \\ []) do
    impl().chat(api_key, model, system_prompt, messages, opts)
  end

  @doc "Backward-compatible single-turn completion."
  def complete(api_key, model, system_prompt, user_message, opts \\ []) do
    messages = [%{role: "user", content: user_message}]

    case chat(api_key, model, system_prompt, messages, opts) do
      {:ok, %{content: content}} ->
        text =
          content
          |> Enum.find_value(fn
            %{"type" => "text", "text" => t} -> t
            _ -> nil
          end)

        if text, do: {:ok, text}, else: {:error, :no_text_in_response}

      error ->
        error
    end
  end

  defp impl do
    Application.get_env(:norns, __MODULE__, [])
    |> Keyword.get(:module, Norns.LLM.Anthropic)
  end
end
