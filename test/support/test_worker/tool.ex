defmodule Norns.TestWorker.Tool do
  @moduledoc """
  A tool as the worker that runs it knows it: the declaration, plus the
  function to call.

  The orchestrator's `Norns.Tools.Tool` has no handler, because it never
  executes anything. This is the other half, and it lives on the worker
  side — here in test support, and in the SDKs for real workers.
  """

  @enforce_keys [:name, :handler]
  defstruct [:name, :handler, description: "", input_schema: %{}, source: :local, side_effect?: false]

  @type t :: %__MODULE__{
          name: String.t(),
          handler: (map() -> {:ok, String.t()} | {:error, String.t()}),
          description: String.t(),
          input_schema: map(),
          source: :local | {:remote, term()},
          side_effect?: boolean()
        }

  @doc "How this tool is declared to the orchestrator when the worker registers."
  def to_def(%__MODULE__{} = tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "input_schema" => tool.input_schema,
      "side_effect" => tool.side_effect?
    }
  end
end
