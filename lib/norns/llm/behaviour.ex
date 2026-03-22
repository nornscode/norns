defmodule Norns.LLM.Behaviour do
  @moduledoc "Behaviour for LLM backends. Allows swapping in fakes for tests."

  @type message :: %{role: String.t(), content: term()}
  @type tool :: %{name: String.t(), description: String.t(), input_schema: map()}
  @type response :: %{
          content: list(),
          stop_reason: String.t(),
          usage: %{input_tokens: integer(), output_tokens: integer()}
        }

  @callback chat(
              api_key :: String.t(),
              model :: String.t(),
              system_prompt :: String.t(),
              messages :: [message()],
              opts :: keyword()
            ) :: {:ok, response()} | {:error, term()}
end
