defmodule Norns.Tools.Tool do
  @moduledoc "A tool that an agent can invoke during execution."

  @enforce_keys [:name, :description, :input_schema, :handler]
  defstruct [:name, :description, :input_schema, :handler, source: :local, side_effect?: false]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          handler: (map() -> {:ok, String.t()} | {:error, String.t()}),
          source: :local | {:remote, term()},
          side_effect?: boolean()
        }

  @doc "Convert to the provider-neutral tool format for LLM dispatch."
  def to_api_format(%__MODULE__{} = tool) do
    %{
      name: tool.name,
      description: tool.description,
      parameters: tool.input_schema
    }
  end
end
