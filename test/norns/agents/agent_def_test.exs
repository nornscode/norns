defmodule Norns.Agents.AgentDefTest do
  use Norns.DataCase, async: true

  alias Norns.Agents.AgentDef
  alias Norns.Tools.{Tool, WebSearch}

  describe "new/1" do
    test "builds a valid definition with documented defaults" do
      assert {:ok, agent_def} =
               AgentDef.new(%{
                 "model" => "claude-sonnet-4-20250514",
                 "system_prompt" => "You are helpful."
               })

      assert agent_def.model == "claude-sonnet-4-20250514"
      assert agent_def.system_prompt == "You are helpful."
      assert agent_def.mode == :task
      assert agent_def.context_strategy == :sliding_window
      assert agent_def.context_window == 20
      assert agent_def.checkpoint_policy == :on_tool_call
      assert agent_def.max_steps == 50
      assert agent_def.on_failure == :stop
      assert agent_def.tools == []
    end

    test "accepts older payloads without version when optional fields are omitted" do
      assert {:ok, agent_def} =
               AgentDef.new(%{
                 "model" => "claude-sonnet-4-20250514",
                 "system_prompt" => "You are helpful.",
                 "mode" => "conversation"
               })

      assert agent_def.mode == :conversation
      assert agent_def.context_strategy == :sliding_window
    end

    test "returns stable error details for missing required fields" do
      assert {:error, %{code: "missing_required_field", field: "model", message: "model is required"}} =
               AgentDef.new(%{"system_prompt" => "You are helpful."})
    end

    test "returns stable error details for invalid enum values" do
      assert {:error,
              %{code: "invalid_field", field: "mode", message: "mode must be one of: task, conversation"}} =
               AgentDef.new(%{
                 "model" => "claude-sonnet-4-20250514",
                 "system_prompt" => "You are helpful.",
                 "mode" => "freeform"
               })
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

    test "includes tool modules" do
      tenant = create_tenant()
      agent = create_agent(tenant)

      agent_def = AgentDef.from_agent(agent, tool_modules: [WebSearch])

      assert length(agent_def.tools) == 1
      assert hd(agent_def.tools).name == "web_search"
    end

    test "includes raw tool structs" do
      tenant = create_tenant()
      agent = create_agent(tenant)

      tool = WebSearch.__tool__()
      agent_def = AgentDef.from_agent(agent, tools: [tool])

      assert length(agent_def.tools) == 1
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

    test "reads mode and context defaults from model_config" do
      tenant = create_tenant()

      agent =
        create_agent(tenant, %{
          model_config: %{
            "mode" => "conversation",
            "context_strategy" => "none",
            "context_window" => "12"
          }
        })

      agent_def = AgentDef.from_agent(agent)
      assert agent_def.mode == :conversation
      assert agent_def.context_strategy == :none
      assert agent_def.context_window == 12
    end
  end
end
