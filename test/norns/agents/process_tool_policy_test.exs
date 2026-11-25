defmodule Norns.Agents.ProcessToolPolicyTest do
  use Norns.DataCase, async: false

  alias Norns.Runs
  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.TestWorker.LLM
  alias Norns.TestWorker.Tool

  setup do
    tenant = create_tenant()
    %{tenant: tenant}
  end

  defp tool(name) do
    %Tool{
      name: name,
      description: "test tool #{name}",
      input_schema: %{},
      handler: fn _ -> {:ok, "result from #{name}"} end
    }
  end

  defp allowlist_agent(tenant, allowed) do
    create_agent(tenant, %{
      model_config: %{"tools" => %{"mode" => "allowlist", "allowed_tools" => allowed}}
    })
  end

  defp subscribe_and_send(pid, agent_id, content) do
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent_id}")
    AgentProcess.send_message(pid, content)
  end

  defp wait_for(event, timeout \\ 5000) do
    receive do
      {^event, payload} -> payload
    after
      timeout -> flunk("Did not receive #{event} within #{timeout}ms")
    end
  end

  describe "tool advertisement" do
    test "allowlist filters offered tools; built-ins are exempt", %{tenant: tenant} do
      agent = allowlist_agent(tenant, ["allowed_tool"])

      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "done"}], stop_reason: "end_turn"}
      ])

      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: agent.id,
          tenant_id: tenant.id,
          tools: [tool("allowed_tool"), tool("forbidden_tool")]
        )

      subscribe_and_send(pid, agent.id, "hello")
      wait_for(:completed)

      run = Runs.get_run!(AgentProcess.get_state(pid).run_id)
      request = Enum.find(Runs.list_events(run.id), &(&1.event_type == "llm_request"))
      offered = request.payload["tools"]

      assert "allowed_tool" in offered
      refute "forbidden_tool" in offered

      for builtin <- ["wait", "ask_human", "launch_agent", "list_agents"] do
        assert builtin in offered
      end
    end

    test "the default (no policy configured) offers everything", %{tenant: tenant} do
      agent = create_agent(tenant)

      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "done"}], stop_reason: "end_turn"}
      ])

      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: agent.id,
          tenant_id: tenant.id,
          tools: [tool("allowed_tool"), tool("forbidden_tool")]
        )

      subscribe_and_send(pid, agent.id, "hello")
      wait_for(:completed)

      run = Runs.get_run!(AgentProcess.get_state(pid).run_id)
      request = Enum.find(Runs.list_events(run.id), &(&1.event_type == "llm_request"))

      assert "allowed_tool" in request.payload["tools"]
      assert "forbidden_tool" in request.payload["tools"]
    end
  end

  describe "dispatch enforcement" do
    test "a call to a tool outside the allowlist is denied with an audit event", %{tenant: tenant} do
      agent = allowlist_agent(tenant, ["allowed_tool"])

      LLM.set_responses([
        %{
          content: [
            %{"type" => "tool_use", "id" => "call_1", "name" => "web_search", "input" => %{"query" => "x"}}
          ],
          stop_reason: "tool_use"
        },
        %{content: [%{"type" => "text", "text" => "understood"}], stop_reason: "end_turn"}
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "search for x")
      wait_for(:completed)

      run = Runs.get_run!(AgentProcess.get_state(pid).run_id)
      events = Runs.list_events(run.id)
      assert run.status == "completed"

      denial = Enum.find(events, &(&1.event_type == "tool_call_denied"))
      assert denial.payload["tool_name"] == "web_search"
      assert denial.payload["reason"] == "not_allowlisted"
      assert denial.payload["mode"] == "allowlist"
      assert denial.payload["requesting_agent_id"] == agent.id

      result =
        Enum.find(events, fn e ->
          e.event_type == "tool_result" and e.payload["tool_call_id"] == "call_1"
        end)

      assert result.payload["is_error"] == true
      assert result.payload["kind"] == "tool_denied"
      assert result.payload["data"]["tool_name"] == "web_search"

      # The denial fed back to the LLM, which ran again and finished.
      assert Enum.count(events, &(&1.event_type == "llm_request")) == 2
    end

    test "built-ins still work under an empty allowlist", %{tenant: tenant} do
      agent = allowlist_agent(tenant, [])

      LLM.set_responses([
        %{
          content: [
            %{"type" => "tool_use", "id" => "call_ask", "name" => "ask_human", "input" => %{"question" => "Which channel?"}}
          ],
          stop_reason: "tool_use"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "post the report")

      payload = wait_for(:waiting_for_user)
      assert payload.question == "Which channel?"

      run = Runs.get_run!(AgentProcess.get_state(pid).run_id)
      refute Enum.any?(Runs.list_events(run.id), &(&1.event_type == "tool_call_denied"))
    end

    test "an allowed tool call dispatches normally under an allowlist", %{tenant: tenant} do
      agent = allowlist_agent(tenant, ["web_search"])

      LLM.set_responses([
        %{
          content: [
            %{"type" => "tool_use", "id" => "call_1", "name" => "web_search", "input" => %{"query" => "elixir"}}
          ],
          stop_reason: "tool_use"
        },
        %{content: [%{"type" => "text", "text" => "found it"}], stop_reason: "end_turn"}
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "search for elixir")
      wait_for(:completed)

      run = Runs.get_run!(AgentProcess.get_state(pid).run_id)
      events = Runs.list_events(run.id)
      assert run.status == "completed"

      refute Enum.any?(events, &(&1.event_type == "tool_call_denied"))

      result =
        Enum.find(events, fn e ->
          e.event_type == "tool_result" and e.payload["tool_call_id"] == "call_1"
        end)

      assert result.payload["is_error"] == false
      assert result.payload["content"] =~ "Search results"
    end
  end

  describe "withheld built-ins" do
    defp builtins_agent(tenant, builtins) do
      create_agent(tenant, %{model_config: %{"tools" => %{"builtins" => builtins}}})
    end

    test "are not offered to the model", %{tenant: tenant} do
      agent = builtins_agent(tenant, ["list_agents"])

      LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "done"}], stop_reason: "end_turn"}
      ])

      {:ok, pid} =
        AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id, tools: [tool("worker_tool")])

      subscribe_and_send(pid, agent.id, "hello")
      wait_for(:completed)

      run = Runs.get_run!(AgentProcess.get_state(pid).run_id)
      request = Enum.find(Runs.list_events(run.id), &(&1.event_type == "llm_request"))
      offered = request.payload["tools"]

      assert "list_agents" in offered
      assert "worker_tool" in offered

      for withheld <- ["wait", "ask_human", "launch_agent", "list_runs", "inspect_run"] do
        refute withheld in offered
      end
    end

    for name <- ["wait", "ask_human", "launch_agent", "list_agents", "list_runs", "inspect_run"] do
      test "a call to a withheld #{name} is denied, not executed", %{tenant: tenant} do
        name = unquote(name)
        agent = builtins_agent(tenant, [])

        input =
          case name do
            "wait" -> %{"seconds" => 60}
            "ask_human" -> %{"question" => "Which channel?"}
            "launch_agent" -> %{"agent_name" => "anyone", "message" => "go"}
            "inspect_run" -> %{"run_id" => 1}
            _ -> %{}
          end

        LLM.set_responses([
          %{
            content: [%{"type" => "tool_use", "id" => "call_1", "name" => name, "input" => input}],
            stop_reason: "tool_use"
          },
          %{content: [%{"type" => "text", "text" => "understood"}], stop_reason: "end_turn"}
        ])

        {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
        subscribe_and_send(pid, agent.id, "go")
        wait_for(:completed)

        run = Runs.get_run!(AgentProcess.get_state(pid).run_id)
        events = Runs.list_events(run.id)
        assert run.status == "completed"

        denial = Enum.find(events, &(&1.event_type == "tool_call_denied"))
        assert denial.payload["tool_name"] == name
        assert denial.payload["reason"] == "builtin_withheld"

        result =
          Enum.find(events, fn e ->
            e.event_type == "tool_result" and e.payload["tool_call_id"] == "call_1"
          end)

        assert result.payload["is_error"] == true
        assert result.payload["kind"] == "tool_denied"

        # None of the built-in's own effects happened.
        for type <- ["waiting_for_timer", "waiting_for_user", "subagent_launched", "subagent_launch_denied", "subagent_list_allowed"] do
          refute Enum.any?(events, &(&1.event_type == type)), "unexpected #{type}"
        end

        assert Enum.count(events, &(&1.event_type == "llm_request")) == 2
      end
    end
  end
end
