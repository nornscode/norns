defmodule Norns.Agents.AgentDef do
  @moduledoc """
  Declarative agent definition. Configures model, tools, checkpoint policy,
  and failure recovery for an agent process.
  """

  @enforce_keys [:model, :system_prompt]
  defstruct [
    :model,
    :system_prompt,
    context_strategy: :sliding_window,
    context_window: 20,
    tools: [],
    checkpoint_policy: :on_tool_call,
    max_steps: 50,
    on_failure: :stop
  ]

  @type context_strategy :: :sliding_window | :none
  @type checkpoint_policy :: :every_step | :on_tool_call | :manual
  @type failure_policy :: :stop | :retry_last_step

  @type t :: %__MODULE__{
          model: String.t(),
          system_prompt: String.t(),
          context_strategy: context_strategy(),
          context_window: pos_integer(),
          tools: [Norns.Tools.Tool.t()],
          checkpoint_policy: checkpoint_policy(),
          max_steps: pos_integer(),
          on_failure: failure_policy()
        }

  @current_version 1
  @defaults %{
    "context_strategy" => :sliding_window,
    "context_window" => 20,
    "tools" => [],
    "checkpoint_policy" => :on_tool_call,
    "max_steps" => 50,
    "on_failure" => :stop
  }

  @doc "Validate and build an AgentDef from a map-shaped external definition."
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_version(Map.get(attrs, "version", @current_version)),
         {:ok, model} <- fetch_required_string(attrs, "model"),
         {:ok, system_prompt} <- fetch_required_string(attrs, "system_prompt"),
         {:ok, context_strategy} <-
           parse_enum(attrs, "context_strategy", %{"sliding_window" => :sliding_window, "none" => :none}),
         {:ok, checkpoint_policy} <-
           parse_enum(attrs, "checkpoint_policy", %{"every_step" => :every_step, "on_tool_call" => :on_tool_call, "manual" => :manual}),
         {:ok, on_failure} <- parse_enum(attrs, "on_failure", %{"stop" => :stop, "retry_last_step" => :retry_last_step}),
         {:ok, context_window} <- parse_positive_integer(attrs, "context_window"),
         {:ok, max_steps} <- parse_positive_integer(attrs, "max_steps"),
         {:ok, tools} <- parse_tools(attrs) do
      {:ok,
       %__MODULE__{
         model: model,
         system_prompt: system_prompt,
         context_strategy: context_strategy,
         context_window: context_window,
         tools: tools,
         checkpoint_policy: checkpoint_policy,
         max_steps: max_steps,
         on_failure: on_failure
       }}
    end
  end

  @doc "Build an AgentDef from an Agent schema record and optional tool modules."
  def from_agent(%Norns.Agents.Agent{} = agent, opts \\ []) do
    tool_modules = Keyword.get(opts, :tool_modules, [])
    extra_tools = Keyword.get(opts, :tools, [])
    config = agent.model_config || %{}

    module_tools = Enum.map(tool_modules, fn mod -> mod.__tool__() end)

    %__MODULE__{
      model: agent.model,
      system_prompt: agent.system_prompt,
      context_strategy: parse_context_strategy(config),
      context_window: parse_context_window(config),
      tools: module_tools ++ extra_tools,
      max_steps: agent.max_steps || 50,
      checkpoint_policy: parse_checkpoint_policy(config),
      on_failure: parse_failure_policy(config)
    }
  end

  defp parse_context_strategy(%{"context_strategy" => "none"}), do: :none
  defp parse_context_strategy(_), do: :sliding_window

  defp parse_context_window(%{"context_window" => value}) when is_integer(value) and value > 0,
    do: value

  defp parse_context_window(%{"context_window" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 20
    end
  end

  defp parse_context_window(_), do: 20

  defp parse_checkpoint_policy(%{"checkpoint_policy" => "every_step"}), do: :every_step
  defp parse_checkpoint_policy(%{"checkpoint_policy" => "manual"}), do: :manual
  defp parse_checkpoint_policy(_), do: :on_tool_call

  defp parse_failure_policy(%{"on_failure" => "retry_last_step"}), do: :retry_last_step
  defp parse_failure_policy(_), do: :stop

  defp validate_version(@current_version), do: :ok

  defp validate_version(version) when is_integer(version) do
    {:error,
     %{
       code: "unsupported_version",
       message: "agent definition version #{version} is not supported",
       field: "version"
     }}
  end

  defp validate_version(_other) do
    {:error, %{code: "invalid_field", message: "version must be an integer", field: "version"}}
  end

  defp fetch_required_string(attrs, field) do
    case Map.get(attrs, field) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      nil ->
        {:error, %{code: "missing_required_field", message: "#{field} is required", field: field}}

      _other ->
        {:error, %{code: "invalid_field", message: "#{field} must be a non-empty string", field: field}}
    end
  end

  defp parse_enum(attrs, field, allowed) do
    case Map.get(attrs, field) do
      nil ->
        {:ok, Map.fetch!(@defaults, field)}

      value when is_binary(value) ->
        case Map.fetch(allowed, value) do
          {:ok, normalized} ->
            {:ok, normalized}

          :error ->
            {:error,
             %{
               code: "invalid_field",
               message: "#{field} must be one of: #{allowed |> Map.keys() |> Enum.sort() |> Enum.join(", ")}",
               field: field
             }}
        end

      _other ->
        {:error, %{code: "invalid_field", message: "#{field} must be a string", field: field}}
    end
  end

  defp parse_positive_integer(attrs, field) do
    case Map.get(attrs, field) do
      nil ->
        {:ok, Map.fetch!(@defaults, field)}

      value when is_integer(value) and value > 0 ->
        {:ok, value}

      _other ->
        {:error, %{code: "invalid_field", message: "#{field} must be a positive integer", field: field}}
    end
  end

  defp parse_tools(%{"tools" => tools}) when is_list(tools), do: {:ok, tools}
  defp parse_tools(%{"tools" => _other}), do: {:error, %{code: "invalid_field", message: "tools must be a list", field: "tools"}}
  defp parse_tools(_attrs), do: {:ok, Map.fetch!(@defaults, "tools")}
end
