defmodule Norns.Agents.SubagentConversation do
  @moduledoc """
  Which conversation a sub-agent's run lands in when another agent launches it.

  Parsed from the *child* agent's `model_config` under the
  `"subagent_conversation"` key:

      {"subagent_conversation": "per_parent"}

  Values:

    * `:per_launch` — every `launch_agent` call starts a fresh conversation
      (the default, and the behaviour before this setting existed). The child
      remembers nothing between assignments, and any number of copies of it
      can run at once.
    * `:per_parent` — every launch from the same parent conversation lands in
      one child conversation, keyed `"subagent:<parent conversation id>"`.
      The child keeps its history across assignments within a session, and
      because a conversation is one process, a launch that arrives while the
      child is still working is refused (`subagent_busy`) rather than starting
      a second copy beside it.

  It belongs to the child, not the launcher, because it describes what the
  child is: a coder that edits a working tree wants one continuous memory and
  one writer at a time; a read-only explorer wants neither. The launcher does
  not get to decide that a child is safe to run twice.

  The key is scoped by the child agent already — the process registry and the
  conversation's unique index are both per agent — so it only has to be
  unique among one agent's conversations. A parent run with no conversation
  has nothing to key on and falls back to a fresh conversation per launch.

  Defaults are deliberately permissive so that adding the setting doesn't
  change behaviour for agents that don't configure it.
  """

  @type t :: :per_launch | :per_parent

  @doc "Parse the setting out of an agent's `model_config`. Unknown values fall back to `:per_launch`."
  @spec from_config(map() | nil) :: t()
  def from_config(%{"subagent_conversation" => "per_parent"}), do: :per_parent
  def from_config(_), do: :per_launch

  @doc """
  The conversation key for one launch of a child.

  `tool_call_id` names the `launch_agent` call; `parent_conversation_id` is
  the launching run's conversation, or nil.
  """
  @spec key(t(), String.t() | nil, integer() | String.t() | nil) :: String.t()
  def key(:per_parent, _tool_call_id, parent_conversation_id) when not is_nil(parent_conversation_id),
    do: "subagent:#{parent_conversation_id}"

  def key(_mode, tool_call_id, _parent_conversation_id),
    do: "subagent_#{tool_call_id}_#{System.unique_integer([:positive])}"
end
