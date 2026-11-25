defmodule Norns.Agents.ToolPolicy do
  @moduledoc """
  Per-agent selection of worker-provided tools.

  Parsed from an agent's `model_config` under the `"tools"` key:

      {
        "tools": {
          "mode": "allowlist",
          "allowed_tools": ["post_to_slack", "get_call_count"]
        }
      }

  Modes:

    * `:open` — the agent is offered every tool registered in the tenant (the
      default, and the behaviour before this policy existed)
    * `:allowlist` — the agent is offered only the tools named in
      `allowed_tools`

  `mode` and `allowed_tools` govern worker-provided tools and the agent's
  own. Built-ins (`wait`, `ask_human`, `launch_agent`, `list_agents`,
  `list_runs`, `inspect_run`) are orchestrator semantics and are never
  selected by the allowlist; they have a separate `builtins` list instead,
  naming the ones the agent is offered:

      {
        "tools": {
          "builtins": ["list_agents", "launch_agent"]
        }
      }

  Leaving `builtins` out offers all of them; `[]` withholds all of them. An
  agent that answers in a shared conversation should not `wait`, and one a
  waiting parent calls should not `ask_human` — the definition says so here
  rather than a worker stripping the tools before the model sees them.
  `launch_agent` and `list_agents` additionally answer to
  `Norns.Agents.SubagentPolicy` when offered.

  The policy is enforced twice: the allowlist filters which tools are
  advertised to the LLM, and dispatch rejects a call to a tool outside it —
  a model can name a tool it was never offered, or the allowlist can change
  mid-conversation. Denials are audited as `tool_call_denied` events; allowed
  calls are not, since `llm_request` already records the offered tool names
  and tool calls are the hot path.

  Defaults are deliberately permissive so that adding the policy doesn't
  change behaviour for agents that don't configure it.
  """

  alias Norns.Tools.Builtins

  defstruct mode: :open, allowed_tools: [], builtins: :all

  @type mode :: :open | :allowlist

  @type t :: %__MODULE__{
          mode: mode(),
          allowed_tools: [String.t()],
          builtins: :all | [String.t()]
        }

  @doc "Parse a policy out of an agent's `model_config`. Unknown values fall back to the permissive default."
  @spec from_config(map() | nil) :: t()
  def from_config(config) when is_map(config) do
    case Map.get(config, "tools") do
      settings when is_map(settings) ->
        %__MODULE__{
          mode: parse_mode(Map.get(settings, "mode")),
          allowed_tools: parse_allowed(Map.get(settings, "allowed_tools")),
          builtins: parse_builtins(Map.get(settings, "builtins"))
        }

      _ ->
        %__MODULE__{}
    end
  end

  def from_config(_), do: %__MODULE__{}

  @doc """
  Whether this agent may call `tool_name`.

  A built-in's name answers to `builtins`, anything else to the allowlist.
  Returns `:ok`, or `{:error, reason}` with a stable code suitable for the
  audit event: `"builtin_withheld"` or `"not_allowlisted"`.
  """
  @spec authorize(t(), String.t()) :: :ok | {:error, String.t()}
  def authorize(%__MODULE__{} = policy, tool_name) do
    if Builtins.builtin?(tool_name),
      do: authorize_builtin(policy, tool_name),
      else: authorize_regular(policy, tool_name)
  end

  defp authorize_builtin(%__MODULE__{builtins: :all}, _name), do: :ok

  defp authorize_builtin(%__MODULE__{builtins: offered}, name) do
    if name in offered, do: :ok, else: {:error, "builtin_withheld"}
  end

  defp authorize_regular(%__MODULE__{mode: :open}, _tool_name), do: :ok

  defp authorize_regular(%__MODULE__{mode: :allowlist, allowed_tools: allowed}, tool_name) do
    if tool_name in allowed, do: :ok, else: {:error, "not_allowlisted"}
  end

  @doc "Filter a tool list down to those the policy allows. Accepts `Norns.Tools.Tool` structs or map-shaped tool defs."
  @spec filter(t(), [Norns.Tools.Tool.t() | map()]) :: [Norns.Tools.Tool.t() | map()]
  def filter(%__MODULE__{mode: :open, builtins: :all}, tools), do: tools

  def filter(%__MODULE__{} = policy, tools) do
    Enum.filter(tools, fn tool -> authorize(policy, tool_name(tool)) == :ok end)
  end

  defp tool_name(%{name: name}), do: name
  defp tool_name(%{"name" => name}), do: name
  defp tool_name(_), do: nil

  defp parse_mode("allowlist"), do: :allowlist
  defp parse_mode(_), do: :open

  defp parse_allowed(names) when is_list(names), do: Enum.filter(names, &is_binary/1)
  defp parse_allowed(_), do: []

  # Unknown names are dropped rather than rejected, like the rest of the
  # policy: a typo withholds a built-in, it never grants a new one.
  defp parse_builtins(names) when is_list(names), do: Enum.filter(names, &Builtins.builtin?/1)
  defp parse_builtins(_), do: :all
end
