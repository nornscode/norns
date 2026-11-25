defmodule Norns.Agents.ToolPolicyTest do
  use ExUnit.Case, async: true

  alias Norns.Agents.ToolPolicy
  alias Norns.Tools.Tool

  describe "from_config/1" do
    test "defaults to open" do
      policy = ToolPolicy.from_config(%{})

      assert policy.mode == :open
      assert policy.allowed_tools == []
    end

    test "reads an allowlist when configured" do
      policy =
        ToolPolicy.from_config(%{
          "tools" => %{"mode" => "allowlist", "allowed_tools" => ["post_to_slack"]}
        })

      assert policy.mode == :allowlist
      assert policy.allowed_tools == ["post_to_slack"]
    end

    test "junk config falls back to the permissive default" do
      for junk <- [nil, "allowlist", 42, ["post_to_slack"]] do
        policy = ToolPolicy.from_config(%{"tools" => junk})
        assert policy.mode == :open
      end

      policy = ToolPolicy.from_config(%{"tools" => %{"mode" => "nonsense"}})
      assert policy.mode == :open
    end

    test "non-string entries are dropped from the allowlist" do
      policy =
        ToolPolicy.from_config(%{
          "tools" => %{"mode" => "allowlist", "allowed_tools" => ["ok", 7, nil, %{}]}
        })

      assert policy.allowed_tools == ["ok"]
    end
  end

  describe "from_config/1 builtins" do
    test "absent offers every built-in" do
      assert ToolPolicy.from_config(%{"tools" => %{}}).builtins == :all
      assert ToolPolicy.from_config(%{}).builtins == :all
    end

    test "a list names the built-ins offered, dropping unknown names" do
      policy = ToolPolicy.from_config(%{"tools" => %{"builtins" => ["list_runs", "post_to_slack", 3]}})
      assert policy.builtins == ["list_runs"]
    end

    test "an empty list withholds all of them" do
      assert ToolPolicy.from_config(%{"tools" => %{"builtins" => []}}).builtins == []
    end

    test "a non-list falls back to all" do
      assert ToolPolicy.from_config(%{"tools" => %{"builtins" => "none"}}).builtins == :all
    end
  end

  describe "authorize/2" do
    test "open mode allows anything" do
      assert ToolPolicy.authorize(%ToolPolicy{}, "anything") == :ok
    end

    test "allowlist mode allows only named tools" do
      policy = %ToolPolicy{mode: :allowlist, allowed_tools: ["post_to_slack"]}

      assert ToolPolicy.authorize(policy, "post_to_slack") == :ok
      assert ToolPolicy.authorize(policy, "delete_record") == {:error, "not_allowlisted"}
    end

    test "an empty allowlist denies every worker tool" do
      policy = %ToolPolicy{mode: :allowlist, allowed_tools: []}
      assert ToolPolicy.authorize(policy, "anything") == {:error, "not_allowlisted"}
    end

    test "built-ins answer to builtins, not the allowlist" do
      policy = %ToolPolicy{mode: :allowlist, allowed_tools: ["wait"], builtins: ["ask_human"]}

      assert ToolPolicy.authorize(policy, "ask_human") == :ok
      # Naming a built-in in allowed_tools does not grant it.
      assert ToolPolicy.authorize(policy, "wait") == {:error, "builtin_withheld"}
    end

    test "every built-in can be withheld, list_runs and inspect_run included" do
      policy = %ToolPolicy{builtins: []}

      for name <- Norns.Tools.Builtins.names() do
        assert ToolPolicy.authorize(policy, name) == {:error, "builtin_withheld"}
      end

      # Withholding built-ins leaves an open policy open for everything else.
      assert ToolPolicy.authorize(policy, "post_to_slack") == :ok
    end
  end

  describe "filter/2" do
    defp tool(name), do: %Tool{name: name, description: "", input_schema: %{}}

    test "open mode passes the list through untouched" do
      tools = [tool("a"), tool("b")]
      assert ToolPolicy.filter(%ToolPolicy{}, tools) == tools
    end

    test "allowlist mode keeps only allowed tools, for structs and map defs alike" do
      policy = %ToolPolicy{mode: :allowlist, allowed_tools: ["a"]}
      tools = [tool("a"), tool("b"), %{"name" => "a"}, %{"name" => "c"}]

      assert ToolPolicy.filter(policy, tools) == [tool("a"), %{"name" => "a"}]
    end

    test "builtins filters built-ins even in open mode" do
      policy = %ToolPolicy{builtins: ["wait"]}
      tools = Norns.Tools.Builtins.all() ++ [tool("a")]

      assert Enum.map(ToolPolicy.filter(policy, tools), & &1.name) == ["wait", "a"]
    end
  end
end
