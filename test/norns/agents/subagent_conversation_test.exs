defmodule Norns.Agents.SubagentConversationTest do
  use ExUnit.Case, async: true

  alias Norns.Agents.{Agent, AgentDef, SubagentConversation}

  describe "from_config/1" do
    test "defaults to a fresh conversation per launch" do
      assert SubagentConversation.from_config(%{}) == :per_launch
      assert SubagentConversation.from_config(nil) == :per_launch
      assert SubagentConversation.from_config(%{"subagent_conversation" => "per_launch"}) == :per_launch
    end

    test "per_parent is opted into by name, and anything else stays permissive" do
      assert SubagentConversation.from_config(%{"subagent_conversation" => "per_parent"}) == :per_parent
      assert SubagentConversation.from_config(%{"subagent_conversation" => "shared"}) == :per_launch
      assert SubagentConversation.from_config(%{"subagent_conversation" => true}) == :per_launch
    end

    test "is carried on the child's AgentDef" do
      agent = %Agent{model: "m", system_prompt: "p", model_config: %{"subagent_conversation" => "per_parent"}}
      assert AgentDef.from_agent(agent).subagent_conversation == :per_parent
      assert AgentDef.from_agent(%{agent | model_config: nil}).subagent_conversation == :per_launch
    end
  end

  describe "key/3" do
    test "per_parent keys on the parent's conversation, so every launch lands in one place" do
      assert SubagentConversation.key(:per_parent, "call_1", 42) == "subagent:42"
      assert SubagentConversation.key(:per_parent, "call_2", 42) == "subagent:42"
    end

    test "per_launch is fresh every time, even for the same call id" do
      a = SubagentConversation.key(:per_launch, "call_1", 42)
      b = SubagentConversation.key(:per_launch, "call_1", 42)
      assert "subagent_call_1_" <> _ = a
      refute a == b
    end

    test "per_parent without a parent conversation falls back to per_launch" do
      a = SubagentConversation.key(:per_parent, "call_1", nil)
      assert "subagent_call_1_" <> _ = a
      refute a == SubagentConversation.key(:per_parent, "call_1", nil)
    end
  end
end
