defmodule Norns.Agents.SubagentPolicyTest do
  use ExUnit.Case, async: true

  alias Norns.Agents.SubagentPolicy

  describe "from_config/1" do
    test "defaults are permissive apart from a bounded depth" do
      policy = SubagentPolicy.from_config(%{})

      assert policy.mode == :open
      assert policy.allow_list_agents == true
      assert policy.allow_inspect_runs == true
      assert policy.max_depth == SubagentPolicy.default_max_depth()
    end

    test "allow_inspect_runs can be turned off" do
      policy = SubagentPolicy.from_config(%{"subagents" => %{"allow_inspect_runs" => false}})

      assert policy.allow_inspect_runs == false
      assert SubagentPolicy.authorize_inspect(policy) == {:error, "inspect_runs_disabled"}
    end

    test "reads max_depth when configured" do
      policy = SubagentPolicy.from_config(%{"subagents" => %{"max_depth" => 1}})
      assert policy.max_depth == 1
    end

    test "zero is a valid max_depth, not a missing value" do
      policy = SubagentPolicy.from_config(%{"subagents" => %{"max_depth" => 0}})
      assert policy.max_depth == 0
    end

    test "junk max_depth falls back to the default" do
      for junk <- ["3", -1, 1.5, nil, %{}] do
        policy = SubagentPolicy.from_config(%{"subagents" => %{"max_depth" => junk}})
        assert policy.max_depth == SubagentPolicy.default_max_depth()
      end
    end
  end

  describe "authorize_depth/2" do
    test "allows a child at or under the limit" do
      policy = %SubagentPolicy{max_depth: 3}

      assert SubagentPolicy.authorize_depth(policy, 1) == :ok
      assert SubagentPolicy.authorize_depth(policy, 3) == :ok
    end

    test "denies a child past the limit" do
      policy = %SubagentPolicy{max_depth: 3}
      assert SubagentPolicy.authorize_depth(policy, 4) == {:error, "max_depth"}
    end

    test "max_depth 0 denies every launch" do
      policy = %SubagentPolicy{max_depth: 0}
      assert SubagentPolicy.authorize_depth(policy, 1) == {:error, "max_depth"}
    end

    test "depth is independent of mode — an open policy still has a ceiling" do
      policy = %SubagentPolicy{mode: :open, max_depth: 2}

      assert SubagentPolicy.authorize_launch(policy, "anything") == :ok
      assert SubagentPolicy.authorize_depth(policy, 3) == {:error, "max_depth"}
    end
  end
end
