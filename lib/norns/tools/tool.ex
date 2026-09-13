defmodule Norns.Tools.Tool do
  @moduledoc """
  A tool an agent can be offered, as the orchestrator knows it.

  Name, description, and schema — what the model needs to decide to call it,
  and what a client needs to display it. Deliberately no handler: the
  orchestrator never executes a tool, so it has nothing to hold. Execution
  lives in the worker that advertised the tool, and how it happens is that
  worker's business.
  """

  @enforce_keys [:name, :description, :input_schema]
  defstruct [:name, :description, :input_schema, source: :local, side_effect?: false]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          source: :local | :builtin | {:remote, term()},
          side_effect?: boolean()
        }

  @doc """
  Convert to the provider-neutral tool format for LLM dispatch.

  Matched on shape rather than on this struct: a worker handing an agent its
  own richer tool representation is fine, and core only reads the three
  fields a model needs.
  """
  def to_api_format(%{name: _, description: _, input_schema: _} = tool) do
    %{
      name: tool.name,
      description: tool.description,
      parameters: tool.input_schema
    }
  end
end
