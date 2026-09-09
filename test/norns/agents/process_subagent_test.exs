defmodule Norns.Agents.ProcessSubagentTest do
  use Norns.DataCase, async: false

  alias Norns.Runs
  alias Norns.Agents.Process, as: AgentProcess
  alias Norns.LLM.Fake

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)

    %{tenant: tenant, agent: agent}
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

  describe "list_agents tool" do
    test "returns available agents excluding self", %{tenant: tenant, agent: agent} do
      _other_agent = create_agent(tenant, %{name: "helper-agent", purpose: "Helps with tasks"})

      Fake.set_responses([
        # LLM calls list_agents
        %{
          content: [
            %{"type" => "tool_use", "id" => "call_list", "name" => "list_agents", "input" => %{}}
          ],
          stop_reason: "tool_use"
        },
        # LLM completes after seeing the result
        %{
          content: [%{"type" => "text", "text" => "Found agents."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "List agents")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle

      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)
      event_types = Enum.map(events, & &1.event_type)

      assert "tool_call" in event_types
      assert "tool_result" in event_types

      # Find the tool_result event for list_agents
      tool_result = Enum.find(events, &(&1.event_type == "tool_result" && &1.payload["name"] == "list_agents"))
      assert tool_result != nil

      assert tool_result.payload["kind"] == "list_agents"
      agent_names = Enum.map(tool_result.payload["data"]["agents"], & &1["name"])

      # Should include other agent but NOT self
      assert "helper-agent" in agent_names
      refute agent.name in agent_names
    end
  end

  describe "launch_agent tool" do
    test "launches child agent and returns its output", %{tenant: tenant, agent: agent} do
      _child_agent = create_agent(tenant, %{name: "child-agent", purpose: "Child worker"})

      Fake.set_responses([
        # Parent: calls launch_agent
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_launch",
              "name" => "launch_agent",
              "input" => %{"agent_name" => "child-agent", "message" => "Do the thing"}
            }
          ],
          stop_reason: "tool_use"
        },
        # Child agent: responds (Fake is shared, child picks up next response)
        %{
          content: [%{"type" => "text", "text" => "Child completed the task."}],
          stop_reason: "end_turn"
        },
        # Parent: uses the child result
        %{
          content: [%{"type" => "text", "text" => "Done, child said it completed."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Launch child")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle

      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)
      event_types = Enum.map(events, & &1.event_type)

      assert "tool_call" in event_types
      assert "subagent_launched" in event_types

      launched = Enum.find(events, &(&1.event_type == "subagent_launched"))
      assert launched.payload["child_agent_name"] == "child-agent"
      assert launched.payload["tool_call_id"] == "call_launch"
    end

    test "tool result carries the child's run id so the parent can inspect it",
         %{tenant: tenant, agent: agent} do
      _child_agent = create_agent(tenant, %{name: "traceable-child"})

      Fake.set_responses([
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_launch",
              "name" => "launch_agent",
              "input" => %{"agent_name" => "traceable-child", "message" => "work"}
            }
          ],
          stop_reason: "tool_use"
        },
        %{content: [%{"type" => "text", "text" => "child output here"}], stop_reason: "end_turn"},
        %{content: [%{"type" => "text", "text" => "parent done"}], stop_reason: "end_turn"}
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Launch child")
      wait_for(:completed)

      events = Runs.list_events(AgentProcess.get_state(pid).run_id)

      payload =
        events
        |> Enum.find(&(&1.event_type == "tool_result" && &1.payload["name"] == "launch_agent"))
        |> Map.fetch!(:payload)

      assert payload["kind"] == "subagent_completed"
      assert payload["data"]["status"] == "completed"
      assert payload["content"] == "child output here"

      # The run id must actually resolve, and point at the child, not the parent.
      child_run = Runs.get_run!(payload["data"]["run_id"])
      assert child_run.depth == 1
      assert child_run.parent_run_id == AgentProcess.get_state(pid).run_id
    end

    test "a child run records its parent and depth", %{tenant: tenant, agent: agent} do
      _child_agent = create_agent(tenant, %{name: "lineage-child"})

      Fake.set_responses([
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_launch",
              "name" => "launch_agent",
              "input" => %{"agent_name" => "lineage-child", "message" => "work"}
            }
          ],
          stop_reason: "tool_use"
        },
        %{content: [%{"type" => "text", "text" => "done"}], stop_reason: "end_turn"},
        %{content: [%{"type" => "text", "text" => "done"}], stop_reason: "end_turn"}
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "go")
      wait_for(:completed)

      parent_run_id = AgentProcess.get_state(pid).run_id
      parent_run = Runs.get_run!(parent_run_id)

      # A user-initiated run is a root.
      assert parent_run.depth == 0
      assert parent_run.parent_run_id == nil

      launched =
        Runs.list_events(parent_run_id)
        |> Enum.find(&(&1.event_type == "subagent_launched"))

      child_run = Runs.get_run!(String.to_integer(launched.payload["child_run_id"]))
      assert child_run.depth == 1
      assert child_run.parent_run_id == parent_run_id
    end

    test "rejects self-launch", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_self",
              "name" => "launch_agent",
              "input" => %{"agent_name" => agent.name, "message" => "Launch myself"}
            }
          ],
          stop_reason: "tool_use"
        },
        %{
          content: [%{"type" => "text", "text" => "Got an error."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Launch self")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)

      tool_result = Enum.find(events, &(&1.event_type == "tool_result" && &1.payload["name"] == "launch_agent"))
      assert tool_result.payload["is_error"] == true
      assert tool_result.payload["kind"] == "subagent_self"
      assert tool_result.payload["content"] == ""
    end

    test "passes context to child agent via launch_agent tool", %{tenant: tenant, agent: agent} do
      _child_agent = create_agent(tenant, %{name: "context-child", purpose: "Receives context"})

      Fake.set_responses([
        # Parent: calls launch_agent with context
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_ctx",
              "name" => "launch_agent",
              "input" => %{
                "agent_name" => "context-child",
                "message" => "Process this ticket",
                "context" => %{
                  "messages" => [
                    %{"role" => "user", "content" => "Original ticket: printer is broken"},
                    %{"role" => "assistant", "content" => "I'll route this to the right team."}
                  ],
                  "data" => %{"ticket_id" => "T-123", "priority" => "high"}
                }
              }
            }
          ],
          stop_reason: "tool_use"
        },
        # Child agent responds
        %{
          content: [%{"type" => "text", "text" => "Ticket T-123 resolved."}],
          stop_reason: "end_turn"
        },
        # Parent completes
        %{
          content: [%{"type" => "text", "text" => "Child resolved the ticket."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Handle ticket")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle

      # Verify the subagent_launched event includes context
      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)
      launched = Enum.find(events, &(&1.event_type == "subagent_launched"))
      assert launched != nil
      assert launched.payload["context"]["data"]["ticket_id"] == "T-123"
      assert length(launched.payload["context"]["messages"]) == 2

      # Verify child run was created with context in its input
      child_run_id = launched.payload["child_run_id"]
      child_run = Runs.get_run!(child_run_id)
      assert child_run.input["context"] != nil
      assert child_run.input["context"]["data"]["ticket_id"] == "T-123"

      # Verify child run's events show the context was used
      child_events = Runs.list_events(child_run.id)
      llm_request = Enum.find(child_events, &(&1.event_type == "llm_request"))
      assert llm_request != nil
      messages = llm_request.payload["messages"]

      # Should contain inherited messages + data message + user message
      assert length(messages) >= 4

      # Check inherited messages are present
      assert Enum.any?(messages, fn m ->
        m["content"] == "Original ticket: printer is broken" || m[:content] == "Original ticket: printer is broken"
      end)

      # The data context is forwarded as a kinded message, not prose: core
      # never writes the preamble — the LLM worker renders it.
      assert Enum.any?(messages, fn m ->
        (m["kind"] || m[:kind]) == "inherited_context" and
          get_in(m["content"] || m[:content], ["ticket_id"]) == "T-123"
      end)
    end

    test "launch_agent works without context (backward compatible)", %{tenant: tenant, agent: agent} do
      _child_agent = create_agent(tenant, %{name: "no-ctx-child", purpose: "No context"})

      Fake.set_responses([
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_noctx",
              "name" => "launch_agent",
              "input" => %{"agent_name" => "no-ctx-child", "message" => "Do something"}
            }
          ],
          stop_reason: "tool_use"
        },
        %{
          content: [%{"type" => "text", "text" => "Done."}],
          stop_reason: "end_turn"
        },
        %{
          content: [%{"type" => "text", "text" => "Child finished."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Launch without context")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      assert state.status == :idle

      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)
      launched = Enum.find(events, &(&1.event_type == "subagent_launched"))
      assert launched != nil
      # No context field in the event
      refute Map.has_key?(launched.payload, "context")
    end

    test "rejects not-found agent", %{tenant: tenant, agent: agent} do
      Fake.set_responses([
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_nf",
              "name" => "launch_agent",
              "input" => %{"agent_name" => "nonexistent-agent", "message" => "Hello"}
            }
          ],
          stop_reason: "tool_use"
        },
        %{
          content: [%{"type" => "text", "text" => "Agent not found."}],
          stop_reason: "end_turn"
        }
      ])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "Launch nonexistent")
      wait_for(:completed)

      state = AgentProcess.get_state(pid)
      run = Runs.get_run!(state.run_id)
      events = Runs.list_events(run.id)

      tool_result = Enum.find(events, &(&1.event_type == "tool_result" && &1.payload["name"] == "launch_agent"))
      assert tool_result.payload["is_error"] == true
      assert tool_result.payload["kind"] == "subagent_not_found"
    end
  end

  describe "subagent policy" do
    defp policy_agent(tenant, subagents) do
      create_agent(tenant, %{
        name: "policed-agent-#{System.unique_integer([:positive])}",
        model_config: %{"subagents" => subagents}
      })
    end

    defp launch_response(target, id \\ "call_launch") do
      %{
        content: [
          %{
            "type" => "tool_use",
            "id" => id,
            "name" => "launch_agent",
            "input" => %{"agent_name" => target, "message" => "do it"}
          }
        ],
        stop_reason: "tool_use"
      }
    end

    defp list_response(id \\ "call_list") do
      %{
        content: [%{"type" => "tool_use", "id" => id, "name" => "list_agents", "input" => %{}}],
        stop_reason: "tool_use"
      }
    end

    defp done_response, do: %{content: [%{"type" => "text", "text" => "ok"}], stop_reason: "end_turn"}

    defp run_events(pid) do
      state = AgentProcess.get_state(pid)
      Runs.list_events(state.run_id)
    end

    defp launch_tool_result(events) do
      Enum.find(events, &(&1.event_type == "tool_result" && &1.payload["name"] == "launch_agent"))
    end

    test "open mode can launch a same-tenant agent", %{tenant: tenant} do
      target = create_agent(tenant, %{name: "target-open"})
      agent = policy_agent(tenant, %{"mode" => "open"})

      Fake.set_responses([launch_response(target.name), done_response(), done_response()])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "go")
      wait_for(:completed)

      events = run_events(pid)
      assert Enum.any?(events, &(&1.event_type == "subagent_launch_allowed"))
      refute Enum.any?(events, &(&1.event_type == "subagent_launch_denied"))
    end

    test "max_depth=0 denies any launch from a root run", %{tenant: tenant} do
      target = create_agent(tenant, %{name: "target-too-deep"})
      agent = policy_agent(tenant, %{"mode" => "open", "max_depth" => 0})

      Fake.set_responses([launch_response(target.name), done_response()])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "go")
      wait_for(:completed)

      events = run_events(pid)
      denied = Enum.find(events, &(&1.event_type == "subagent_launch_denied"))

      assert denied.payload["reason"] == "max_depth"
      assert denied.payload["target_agent_name"] == target.name
      assert launch_tool_result(events).payload["is_error"] == true

      # Denied means denied — no child run should exist.
      refute Enum.any?(events, &(&1.event_type == "subagent_launched"))
    end

    test "the depth limit is checked before the child is spawned", %{tenant: tenant} do
      target = create_agent(tenant, %{name: "target-never-spawned"})
      agent = policy_agent(tenant, %{"mode" => "open", "max_depth" => 0})

      before = Runs.list_runs(target.id) |> length()

      Fake.set_responses([launch_response(target.name), done_response()])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "go")
      wait_for(:completed)

      assert Runs.list_runs(target.id) |> length() == before
    end

    test "a launch within the depth limit is allowed", %{tenant: tenant} do
      target = create_agent(tenant, %{name: "target-in-depth"})
      agent = policy_agent(tenant, %{"mode" => "open", "max_depth" => 1})

      Fake.set_responses([launch_response(target.name), done_response(), done_response()])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "go")
      wait_for(:completed)

      events = run_events(pid)
      assert Enum.any?(events, &(&1.event_type == "subagent_launch_allowed"))
      refute Enum.any?(events, &(&1.event_type == "subagent_launch_denied"))
    end

    test "allowlist mode allows a listed target", %{tenant: tenant} do
      target = create_agent(tenant, %{name: "target-listed"})
      agent = policy_agent(tenant, %{"mode" => "allowlist", "allowed_agents" => [target.name]})

      Fake.set_responses([launch_response(target.name), done_response(), done_response()])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "go")
      wait_for(:completed)

      assert Enum.any?(run_events(pid), &(&1.event_type == "subagent_launch_allowed"))
    end

    test "allowlist mode denies an unlisted target", %{tenant: tenant} do
      target = create_agent(tenant, %{name: "target-unlisted"})
      agent = policy_agent(tenant, %{"mode" => "allowlist", "allowed_agents" => ["someone-else"]})

      Fake.set_responses([launch_response(target.name), done_response()])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "go")
      wait_for(:completed)

      events = run_events(pid)
      denied = Enum.find(events, &(&1.event_type == "subagent_launch_denied"))

      assert denied.payload["reason"] == "not_allowlisted"
      assert denied.payload["target_agent_name"] == target.name
      assert denied.payload["mode"] == "allowlist"
      assert denied.payload["requesting_agent_id"] == agent.id

      assert launch_tool_result(events).payload["is_error"] == true
    end

    test "disabled mode denies any launch", %{tenant: tenant} do
      target = create_agent(tenant, %{name: "target-disabled"})
      agent = policy_agent(tenant, %{"mode" => "disabled"})

      Fake.set_responses([launch_response(target.name), done_response()])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "go")
      wait_for(:completed)

      events = run_events(pid)
      denied = Enum.find(events, &(&1.event_type == "subagent_launch_denied"))

      assert denied.payload["reason"] == "disabled"
      assert launch_tool_result(events).payload["kind"] == "subagent_denied"
      assert launch_tool_result(events).payload["data"]["reason"] == "disabled"
    end

    test "a cross-tenant target is never launchable", %{tenant: tenant} do
      other_tenant = create_tenant()
      foreign = create_agent(other_tenant, %{name: "foreign-agent"})
      agent = policy_agent(tenant, %{"mode" => "open"})

      Fake.set_responses([launch_response(foreign.name), done_response()])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "go")
      wait_for(:completed)

      result = launch_tool_result(run_events(pid))
      assert result.payload["is_error"] == true
      assert result.payload["kind"] == "subagent_not_found"
    end

    test "allow_list_agents=false denies listing", %{tenant: tenant} do
      _other = create_agent(tenant, %{name: "visible-agent"})
      agent = policy_agent(tenant, %{"allow_list_agents" => false})

      Fake.set_responses([list_response(), done_response()])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "who is there")
      wait_for(:completed)

      events = run_events(pid)
      denied = Enum.find(events, &(&1.event_type == "subagent_list_denied"))

      assert denied.payload["reason"] == "list_agents_disabled"

      result = Enum.find(events, &(&1.event_type == "tool_result" && &1.payload["name"] == "list_agents"))
      assert result.payload["is_error"] == true
      refute result.payload["content"] =~ "visible-agent"
    end

    test "listing is allowed by default and audited", %{tenant: tenant} do
      _other = create_agent(tenant, %{name: "listable-agent"})
      agent = policy_agent(tenant, %{"mode" => "open"})

      Fake.set_responses([list_response(), done_response()])

      {:ok, pid} = AgentProcess.start_link(agent_id: agent.id, tenant_id: tenant.id)
      subscribe_and_send(pid, agent.id, "who is there")
      wait_for(:completed)

      events = run_events(pid)
      assert Enum.any?(events, &(&1.event_type == "subagent_list_allowed"))

      result = Enum.find(events, &(&1.event_type == "tool_result" && &1.payload["name"] == "list_agents"))
      assert Enum.any?(result.payload["data"]["agents"], &(&1["name"] == "listable-agent"))
    end
  end
end
