defmodule Norns.Tools.Tool do
  @moduledoc "A tool that an agent can invoke during execution."

  @enforce_keys [:name, :description, :input_schema, :handler]
  defstruct [:name, :description, :input_schema, :handler]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          handler: (map() -> {:ok, String.t()} | {:error, String.t()})
        }

  @doc "Convert to the Anthropic API tool format."
  def to_api_format(%__MODULE__{} = tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.input_schema
    }
  end
end
