defmodule Norns.Agents.SubagentPolicy do
  @moduledoc """
  Authorization policy for an agent's use of the `launch_agent` and
  `list_agents` built-ins, and of `list_runs` and `inspect_run`, which let it
  read other agents' runs.

  Parsed from an agent's `model_config` under the `"subagents"` key:

      {
        "subagents": {
          "mode": "allowlist",
          "allowed_agents": ["hello-bot"],
          "allow_list_agents": false,
          "allow_inspect_runs": false,
          "max_depth": 3
        }
      }

  Modes:

    * `:open` — may launch any agent in the same tenant (the default, and the
      behaviour before this policy existed)
    * `:allowlist` — may launch only the agents named in `allowed_agents`
    * `:disabled` — may not launch sub-agents at all

  `allow_list_agents` controls whether `list_agents` is permitted, and
  `allow_inspect_runs` whether `list_runs` and `inspect_run` are. Both read
  only within the agent's tenant.

  `max_depth` bounds how deeply runs may nest, counted from the root run (which
  is depth 0). It stops runaway recursion — an agent that launches an agent that
  launches it back. It is *not* a cost control: a single agent launching fifty
  children at depth 1 is far more expensive than a chain of five, and depth
  says nothing about that.

  Defaults are deliberately permissive so that adding the policy doesn't change
  behaviour for agents that don't configure it. The exception is `max_depth`,
  which defaults to #{3} — previously nesting was unbounded, so an agent
  recursing deeper than that was already misbehaving.
  """

  @default_max_depth 3

  defstruct mode: :open,
            allowed_agents: [],
            allow_list_agents: true,
            allow_inspect_runs: true,
            max_depth: @default_max_depth

  @type mode :: :open | :allowlist | :disabled

  @type t :: %__MODULE__{
          mode: mode(),
          allowed_agents: [String.t()],
          allow_list_agents: boolean(),
          allow_inspect_runs: boolean(),
          max_depth: non_neg_integer()
        }

  @doc "The nesting depth allowed when an agent doesn't configure one."
  def default_max_depth, do: @default_max_depth

  @doc "Parse a policy out of an agent's `model_config`. Unknown values fall back to the permissive default."
  @spec from_config(map() | nil) :: t()
  def from_config(config) when is_map(config) do
    case Map.get(config, "subagents") do
      settings when is_map(settings) ->
        %__MODULE__{
          mode: parse_mode(Map.get(settings, "mode")),
          allowed_agents: parse_allowed(Map.get(settings, "allowed_agents")),
          allow_list_agents: parse_boolean(Map.get(settings, "allow_list_agents"), true),
          allow_inspect_runs: parse_boolean(Map.get(settings, "allow_inspect_runs"), true),
          max_depth: parse_max_depth(Map.get(settings, "max_depth"))
        }

      _ ->
        %__MODULE__{}
    end
  end

  def from_config(_), do: %__MODULE__{}

  @doc """
  Whether this agent may launch `target_name`.

  Returns `:ok`, or `{:error, reason}` where reason is a stable code suitable
  for the audit event: `"disabled"` or `"not_allowlisted"`.
  """
  @spec authorize_launch(t(), String.t()) :: :ok | {:error, String.t()}
  def authorize_launch(%__MODULE__{mode: :disabled}, _target_name), do: {:error, "disabled"}

  def authorize_launch(%__MODULE__{mode: :allowlist, allowed_agents: allowed}, target_name) do
    if target_name in allowed, do: :ok, else: {:error, "not_allowlisted"}
  end

  def authorize_launch(%__MODULE__{mode: :open}, _target_name), do: :ok

  @doc """
  Whether this agent may enumerate other agents.

  Returns `:ok` or `{:error, "list_agents_disabled"}`.
  """
  @spec authorize_list(t()) :: :ok | {:error, String.t()}
  def authorize_list(%__MODULE__{allow_list_agents: true}), do: :ok
  def authorize_list(%__MODULE__{}), do: {:error, "list_agents_disabled"}

  @doc """
  Whether this agent may read the tenant's runs with `list_runs` and
  `inspect_run`.

  Returns `:ok` or `{:error, "inspect_runs_disabled"}`.
  """
  @spec authorize_inspect(t()) :: :ok | {:error, String.t()}
  def authorize_inspect(%__MODULE__{allow_inspect_runs: true}), do: :ok
  def authorize_inspect(%__MODULE__{}), do: {:error, "inspect_runs_disabled"}

  @doc """
  Whether a child at `child_depth` may be launched.

  `child_depth` is absolute — the depth the child run would have, not the
  distance from the launching agent. Returns `:ok` or `{:error, "max_depth"}`.
  """
  @spec authorize_depth(t(), non_neg_integer()) :: :ok | {:error, String.t()}
  def authorize_depth(%__MODULE__{max_depth: max}, child_depth) when child_depth > max,
    do: {:error, "max_depth"}

  def authorize_depth(%__MODULE__{}, _child_depth), do: :ok

  defp parse_mode("allowlist"), do: :allowlist
  defp parse_mode("disabled"), do: :disabled
  defp parse_mode(_), do: :open

  defp parse_allowed(names) when is_list(names), do: Enum.filter(names, &is_binary/1)
  defp parse_allowed(_), do: []

  defp parse_boolean(value, _default) when is_boolean(value), do: value
  defp parse_boolean(_value, default), do: default

  defp parse_max_depth(value) when is_integer(value) and value >= 0, do: value
  defp parse_max_depth(_), do: @default_max_depth
end
