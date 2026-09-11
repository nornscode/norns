defmodule Norns.Agents.AgentDefTest do
  use Norns.DataCase, async: true

  alias Norns.Agents.AgentDef
  alias Norns.Tools.Tool

  describe "new/1" do
    test "builds a valid definition with documented defaults" do
      assert {:ok, agent_def} =
               AgentDef.new(%{
                 "model" => "claude-sonnet-4-20250514",
                 "system_prompt" => "You are helpful."
               })

      assert agent_def.model == "claude-sonnet-4-20250514"
      assert agent_def.system_prompt == "You are helpful."
      assert agent_def.context_strategy == :sliding_window
      assert agent_def.context_window == 20
      assert agent_def.checkpoint_policy == :on_tool_call
      assert agent_def.max_steps == 50
      assert agent_def.on_failure == :stop
      assert agent_def.tools == []
    end

    test "parses context_policy with a default keep" do
      assert {:ok, agent_def} =
               AgentDef.new(%{"model" => "m", "system_prompt" => "p", "context_policy" => %{"compact_at" => 100_000}})

      assert agent_def.context_policy == %{compact_at: 100_000, keep: 20}

      assert {:ok, %{context_policy: nil}} = AgentDef.new(%{"model" => "m", "system_prompt" => "p"})

      assert {:error, %{code: "invalid_field", field: "context_policy"}} =
               AgentDef.new(%{"model" => "m", "system_prompt" => "p", "context_policy" => %{"keep" => 5}})

      assert {:error, %{code: "invalid_field", field: "context_policy"}} =
               AgentDef.new(%{"model" => "m", "system_prompt" => "p", "context_policy" => "big"})
    end

    test "returns stable error details for missing required fields" do
      assert {:error, %{code: "missing_required_field", field: "model", message: "model is required"}} =
               AgentDef.new(%{"system_prompt" => "You are helpful."})
    end

    test "returns explicit version compatibility errors" do
      assert {:error,
              %{
                code: "unsupported_version",
                field: "version",
                message: "agent definition version 2 is not supported"
              }} =
               AgentDef.new(%{
                 "version" => 2,
                 "model" => "claude-sonnet-4-20250514",
                 "system_prompt" => "You are helpful."
               })
    end

    test "accepts explicit tools lists" do
      tool = %Tool{name: "echo", description: "Echo", input_schema: %{}, handler: fn _ -> {:ok, "ok"} end}

      assert {:ok, agent_def} =
               AgentDef.new(%{
                 "model" => "claude-sonnet-4-20250514",
                 "system_prompt" => "You are helpful.",
                 "tools" => [tool]
               })

      assert agent_def.tools == [tool]
    end
  end

  describe "from_agent/2" do
    test "builds AgentDef from Agent schema" do
      tenant = create_tenant()
      agent = create_agent(tenant, %{model: "claude-sonnet-4-20250514", max_steps: 25})

      agent_def = AgentDef.from_agent(agent)

      assert agent_def.model == "claude-sonnet-4-20250514"
      assert agent_def.system_prompt == agent.system_prompt
      assert agent_def.max_steps == 25
      assert agent_def.checkpoint_policy == :on_tool_call
      assert agent_def.on_failure == :stop
      assert agent_def.tools == []
    end

    test "includes raw tool structs" do
      tenant = create_tenant()
      agent = create_agent(tenant)

      tool = %Tool{name: "echo", description: "Echo", input_schema: %{}, handler: fn _ -> {:ok, "ok"} end}
      agent_def = AgentDef.from_agent(agent, tools: [tool])

      assert length(agent_def.tools) == 1
      assert hd(agent_def.tools).name == "echo"
    end

    test "reads checkpoint_policy from model_config" do
      tenant = create_tenant()
      agent = create_agent(tenant, %{model_config: %{"checkpoint_policy" => "every_step"}})

      agent_def = AgentDef.from_agent(agent)
      assert agent_def.checkpoint_policy == :every_step
    end

    test "reads on_failure from model_config" do
      tenant = create_tenant()
      agent = create_agent(tenant, %{model_config: %{"on_failure" => "retry_last_step"}})

      agent_def = AgentDef.from_agent(agent)
      assert agent_def.on_failure == :retry_last_step
    end

    test "reads context defaults from model_config" do
      tenant = create_tenant()

      agent =
        create_agent(tenant, %{
          model_config: %{
            "context_strategy" => "none",
            "context_window" => "12"
          }
        })

      agent_def = AgentDef.from_agent(agent)
      assert agent_def.context_strategy == :none
      assert agent_def.context_window == 12
    end
  end

  describe "max_tokens" do
    test "comes from model_config, and is left to the worker when absent" do
      agent = %Norns.Agents.Agent{model: "claude-sonnet-5", system_prompt: "hi", max_steps: 10}

      assert AgentDef.from_agent(%{agent | model_config: %{"max_tokens" => 32_000}}).max_tokens == 32_000
      assert AgentDef.from_agent(%{agent | model_config: %{}}).max_tokens == nil
      # A nonsense value is ignored rather than breaking the agent.
      assert AgentDef.from_agent(%{agent | model_config: %{"max_tokens" => "lots"}}).max_tokens == nil
    end

    test "a definition rejects a nonsense value outright" do
      base = %{"model" => "claude-sonnet-5", "system_prompt" => "hi"}
      assert {:ok, %{max_tokens: 8192}} = AgentDef.new(Map.put(base, "max_tokens", 8192))
      assert {:ok, %{max_tokens: nil}} = AgentDef.new(base)
      assert {:error, %{field: "max_tokens"}} = AgentDef.new(Map.put(base, "max_tokens", 0))
    end
  end

end
