defmodule NornsWeb.RunControllerTest do
  use NornsWeb.ConnCase, async: false

  setup %{conn: conn} do
    tenant = create_tenant()
    agent = create_agent(tenant)
    conn = authenticated_conn(conn, tenant)
    %{conn: conn, tenant: tenant, agent: agent}
  end

  describe "GET /api/v1/runs/:id" do
    test "shows a run", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{"msg" => "hi"},
          status: "completed",
          output: "hello"
        })

      conn = get(conn, "/api/v1/runs/#{run.id}")
      assert %{"data" => %{"id" => id, "status" => "completed"}} = json_response(conn, 200)
      assert id == run.id
    end

    test "says what the run's LLM calls cost", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: "completed"})

      {:ok, _} =
        Norns.Runs.append_event(run, %{
          event_type: "llm_response",
          source: "system",
          payload: %{"content" => "hi", "step" => 1, "model" => "claude-haiku-4-5", "usage" => %{"input_tokens" => 1_000, "output_tokens" => 100}}
        })

      assert %{"data" => %{"cost" => %{"usd" => "0.001500", "unpriced" => []}, "total_cost" => %{"usd" => "0.001500"}}} =
               json_response(get(conn, "/api/v1/runs/#{run.id}"), 200)
    end

    # What a client needs to hang a child under its parent and to tell that
    # the child is waiting on the user, without reading the event log.
    test "a sub-agent run carries its agent, its parent, and what it is waiting for",
         %{conn: conn, tenant: tenant, agent: agent} do
      child_agent = create_agent(tenant, %{name: "sleipnir-code"})

      {:ok, parent} =
        Norns.Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: "running"})

      {:ok, child} =
        Norns.Runs.create_run(%{
          agent_id: child_agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{},
          status: "waiting",
          parent_run_id: parent.id,
          depth: 1
        })

      {:ok, _} =
        Norns.Runs.append_event(child, %{
          event_type: "waiting_for_user",
          source: "system",
          payload: %{"question" => "Allow bash `make`?", "tool_call_id" => "c1", "step" => 1}
        })

      assert %{"data" => data} = json_response(get(conn, "/api/v1/runs/#{child.id}"), 200)
      assert data["agent_id"] == child_agent.id
      assert data["parent_run_id"] == parent.id
      assert data["status"] == "waiting"
      assert data["waiting_for"]["question"] == "Allow bash `make`?"
    end

    test "includes failure inspector for failed runs", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{"msg" => "hi"},
          status: "failed",
          failure_metadata: %{
            "error_class" => "internal",
            "error_code" => "runtime_failure",
            "retry_decision" => "terminal"
          }
        })

      Norns.Runs.append_event(run, %{
        event_type: "checkpoint_saved",
        payload: %{"messages" => [%{role: "user", content: "hi"}], "step" => 1}
      })

      Norns.Runs.append_event(run, %{
        event_type: "run_failed",
        payload: %{
          "error" => "boom",
          "error_class" => "internal",
          "error_code" => "runtime_failure",
          "retry_decision" => "terminal"
        }
      })

      conn = get(conn, "/api/v1/runs/#{run.id}")
      assert %{"data" => %{"failure_inspector" => inspector, "failure_metadata" => metadata}} = json_response(conn, 200)
      assert Enum.sort(Map.keys(inspector)) == ["error_class", "error_code", "last_checkpoint", "last_event", "retry_decision"]
      assert inspector["error_class"] == "internal"
      assert inspector["error_code"] == "runtime_failure"
      assert inspector["retry_decision"] == "terminal"
      assert inspector["last_checkpoint"]["event_type"] == "checkpoint_saved"
      assert Enum.sort(Map.keys(inspector["last_checkpoint"])) == ["event_type", "inserted_at", "payload", "sequence"]
      assert inspector["last_event"]["event_type"] == "run_failed"
      assert Enum.sort(Map.keys(inspector["last_event"])) == ["event_type", "inserted_at", "payload", "sequence"]
      assert metadata["error_code"] == "runtime_failure"
    end

    test "returns 404 for non-existent run", %{conn: conn} do
      conn = get(conn, "/api/v1/runs/999999")
      assert json_response(conn, 404)
    end

    test "returns 404 for a run from another tenant", %{conn: conn, agent: agent} do
      other_tenant = create_tenant()
      other_agent = create_agent(other_tenant)

      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: other_agent.id,
          tenant_id: other_tenant.id,
          trigger_type: "message",
          input: %{},
          status: "completed"
        })

      conn = get(conn, "/api/v1/runs/#{run.id}")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/runs" do
    test "lists runs for the tenant", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, _} = Norns.Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: "completed", output: "done"})
      {:ok, _} = Norns.Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: "failed"})

      conn = get(conn, "/api/v1/runs")
      assert %{"data" => runs} = json_response(conn, 200)
      assert length(runs) == 2
    end

    test "does not include runs from other tenants", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, _} = Norns.Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: "completed"})

      other_tenant = create_tenant()
      other_agent = create_agent(other_tenant)
      {:ok, _} = Norns.Runs.create_run(%{agent_id: other_agent.id, tenant_id: other_tenant.id, trigger_type: "message", input: %{}, status: "completed"})

      conn = get(conn, "/api/v1/runs")
      assert %{"data" => runs} = json_response(conn, 200)
      assert length(runs) == 1
    end

    test "respects limit parameter", %{conn: conn, tenant: tenant, agent: agent} do
      for _ <- 1..5 do
        Norns.Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: "completed"})
      end

      conn = get(conn, "/api/v1/runs?limit=3")
      assert %{"data" => runs} = json_response(conn, 200)
      assert length(runs) == 3
    end

    test "filters by status and agent in the query, not the page", %{conn: conn, tenant: tenant, agent: agent} do
      other_agent = create_agent(tenant)

      {:ok, parked} = Norns.Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: "waiting"})
      {:ok, other_parked} = Norns.Runs.create_run(%{agent_id: other_agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: "waiting"})

      for _ <- 1..3 do
        {:ok, _} = Norns.Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{}, status: "completed"})
      end

      # The waiting runs are the oldest, so a limit this small would never
      # reach them if the filter applied to the page.
      assert %{"data" => runs} = json_response(get(conn, "/api/v1/runs?status=waiting&limit=2"), 200)
      assert Enum.map(runs, & &1["id"]) |> Enum.sort() == Enum.sort([parked.id, other_parked.id])

      assert %{"data" => [%{"id" => id}]} = json_response(get(conn, "/api/v1/runs?status=waiting&agent_id=#{agent.id}"), 200)
      assert id == parked.id

      assert %{"data" => runs} = json_response(get(conn, "/api/v1/runs?agent_id=#{other_agent.id}"), 200)
      assert length(runs) == 1
    end

    test "rejects an unknown status or a non-integer agent_id", %{conn: conn} do
      assert %{"error" => error} = json_response(get(conn, "/api/v1/runs?status=parked"), 422)
      assert error =~ "waiting"

      assert %{"error" => "agent_id must be an integer"} = json_response(get(conn, "/api/v1/runs?agent_id=bot"), 422)
    end
  end

  describe "POST /api/v1/runs/:id/retry" do
    test "retries a failed run", %{conn: conn, tenant: tenant, agent: agent} do
      Norns.TestWorker.LLM.set_responses([
        %{content: [%{"type" => "text", "text" => "retried"}], stop_reason: "end_turn"}
      ])

      {:ok, run} = Norns.Runs.create_run(%{
        agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message",
        input: %{"user_message" => "hello"}, status: "failed"
      })

      conn = post(conn, "/api/v1/runs/#{run.id}/retry")
      assert %{"status" => "accepted", "run_id" => new_run_id} = json_response(conn, 202)
      assert new_run_id != run.id
    end

    test "rejects retry of a running run", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} = Norns.Runs.create_run(%{
        agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message",
        input: %{"user_message" => "hello"}, status: "running"
      })

      conn = post(conn, "/api/v1/runs/#{run.id}/retry")
      assert json_response(conn, 409)
    end

    test "rejects retry when no user_message", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} = Norns.Runs.create_run(%{
        agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message",
        input: %{}, status: "failed"
      })

      conn = post(conn, "/api/v1/runs/#{run.id}/retry")
      assert json_response(conn, 422)
    end

    test "returns 404 for another tenant's run", %{conn: conn} do
      other_tenant = create_tenant()
      other_agent = create_agent(other_tenant)

      {:ok, run} = Norns.Runs.create_run(%{
        agent_id: other_agent.id, tenant_id: other_tenant.id, trigger_type: "message",
        input: %{"user_message" => "hello"}, status: "failed"
      })

      conn = post(conn, "/api/v1/runs/#{run.id}/retry")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/v1/runs/:id/reply" do
    test "delivers an answer to a parked run", %{conn: conn, tenant: tenant, agent: agent} do
      Norns.TestWorker.LLM.set_responses([
        %{
          content: [
            %{
              "type" => "tool_use",
              "id" => "call_ask",
              "name" => "ask_human",
              "input" => %{"question" => "Proceed?"}
            }
          ],
          stop_reason: "tool_use"
        },
        %{content: [%{"type" => "text", "text" => "Done."}], stop_reason: "end_turn"}
      ])

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")

      {:ok, run_id} =
        Norns.Agents.Registry.send_message(tenant.id, agent.id, "do the thing",
          conversation_key: "hitl-test"
        )

      assert_receive {:waiting_for_user, %{question: "Proceed?"}}, 5000

      conn = post(conn, "/api/v1/runs/#{run_id}/reply", %{"answer" => "yes"})
      assert %{"status" => "accepted"} = json_response(conn, 202)

      assert_receive {:completed, _}, 5000
    end

    test "rejects a reply when the run is not waiting", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} = Norns.Runs.create_run(%{
        agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message",
        input: %{"user_message" => "hello"}, status: "completed"
      })

      conn = post(conn, "/api/v1/runs/#{run.id}/reply", %{"answer" => "yes"})
      assert json_response(conn, 409)
    end

    test "requires an answer", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} = Norns.Runs.create_run(%{
        agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message",
        input: %{"user_message" => "hello"}, status: "running"
      })

      conn = post(conn, "/api/v1/runs/#{run.id}/reply", %{})
      assert json_response(conn, 422)
    end

    test "returns 404 for another tenant's run", %{conn: conn} do
      other_tenant = create_tenant()
      other_agent = create_agent(other_tenant)

      {:ok, run} = Norns.Runs.create_run(%{
        agent_id: other_agent.id, tenant_id: other_tenant.id, trigger_type: "message",
        input: %{"user_message" => "hello"}, status: "running"
      })

      conn = post(conn, "/api/v1/runs/#{run.id}/reply", %{"answer" => "yes"})
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/v1/runs/:id/cancel" do
    defp park_on_question(tenant, agent, key) do
      Norns.TestWorker.LLM.set_responses([
        %{
          content: [
            %{"type" => "tool_use", "id" => "call_ask", "name" => "ask_human", "input" => %{"question" => "Proceed?"}}
          ],
          stop_reason: "tool_use"
        },
        %{content: [%{"type" => "text", "text" => "Done."}], stop_reason: "end_turn"}
      ])

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
      {:ok, run_id} = Norns.Agents.Registry.send_message(tenant.id, agent.id, "do the thing", conversation_key: key)
      assert_receive {:waiting_for_user, %{question: "Proceed?"}}, 5000
      run_id
    end

    test "fails a parked run as cancelled and leaves the conversation usable",
         %{conn: conn, tenant: tenant, agent: agent} do
      run_id = park_on_question(tenant, agent, "cancel-test")

      conn = post(conn, "/api/v1/runs/#{run_id}/cancel")

      assert %{"status" => "cancelled", "run_id" => ^run_id, "data" => %{"status" => "failed"}} =
               json_response(conn, 200)

      assert_receive {:error, %{run_id: ^run_id, error: "Cancelled by user"}}, 5000

      run = Norns.Runs.get_run!(run_id)
      assert run.status == "failed"
      assert run.failure_metadata["error_code"] == "cancelled"
      assert run.failure_metadata["error_class"] == "policy"
      assert Enum.any?(Norns.Runs.list_events(run_id), &(&1.event_type == "run_failed"))

      # The history the next turn is built on pairs the open ask_human call
      # with a result; without one the provider refuses the whole conversation.
      conversation = Norns.Conversations.get_conversation_by_agent_key(agent.id, "cancel-test")
      [%{"role" => "assistant", "tool_calls" => [%{"id" => "call_ask"}]}, settled] = Enum.take(conversation.messages, -2)

      assert %{"role" => "tool", "tool_call_id" => "call_ask", "name" => "ask_human", "is_error" => true,
               "content" => "Cancelled by user", "kind" => "unanswered"} = settled

      assert Enum.any?(Norns.Runs.list_events(run_id), &(&1.event_type == "tool_result" and &1.payload["tool_call_id"] == "call_ask"))

      # The process is idle, not dead: the next message starts a new run.
      Norns.TestWorker.LLM.set_responses([%{content: [%{"type" => "text", "text" => "Again."}], stop_reason: "end_turn"}])
      {:ok, next_id} = Norns.Agents.Registry.send_message(tenant.id, agent.id, "again", conversation_key: "cancel-test")
      assert next_id != run_id
      assert_receive {:completed, %{run_id: ^next_id, output: "Again."}}, 5000
    end

    test "cancels a run sleeping on wait without a stale timer firing later",
         %{conn: conn, tenant: tenant, agent: agent} do
      Norns.TestWorker.LLM.set_responses([
        %{
          content: [%{"type" => "tool_use", "id" => "call_wait", "name" => "wait", "input" => %{"seconds" => 1}}],
          stop_reason: "tool_use"
        },
        %{content: [%{"type" => "text", "text" => "Woke."}], stop_reason: "end_turn"}
      ])

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
      {:ok, run_id} = Norns.Agents.Registry.send_message(tenant.id, agent.id, "nap", conversation_key: "cancel-wait")
      assert_receive {:waiting_timer, %{run_id: ^run_id}}, 5000

      assert %{"status" => "cancelled"} = json_response(post(conn, "/api/v1/runs/#{run_id}/cancel"), 200)
      assert_receive {:error, %{run_id: ^run_id}}, 5000

      # Past when the timer would have fired: the process is still alive and idle.
      Process.sleep(1500)
      {:ok, pid} = Norns.Agents.Registry.lookup(tenant.id, agent.id, "cancel-wait")
      assert Process.alive?(pid)
      assert %{status: :idle} = Norns.Agents.Process.get_state(pid)
      assert Norns.Runs.get_run!(run_id).status == "failed"

      conversation = Norns.Conversations.get_conversation_by_agent_key(agent.id, "cancel-wait")
      assert %{"role" => "tool", "tool_call_id" => "call_wait", "is_error" => true} = List.last(conversation.messages)
    end

    test "fails an orphaned running run directly", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message",
          input: %{"user_message" => "hello"}, status: "running"
        })

      Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent.id}")
      assert %{"status" => "cancelled", "data" => %{"status" => "failed"}} =
               json_response(post(conn, "/api/v1/runs/#{run.id}/cancel"), 200)

      run_id = run.id
      assert_receive {:error, %{run_id: ^run_id, error: "Cancelled by user"}}, 1000
      assert Norns.Runs.get_run!(run_id).failure_metadata["error_code"] == "cancelled"
      assert [%{event_type: "run_failed"}] = Norns.Runs.list_events(run_id)
    end

    test "rejects a run that has already finished", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message",
          input: %{"user_message" => "hello"}, status: "completed"
        })

      assert %{"error" => "run has already finished"} = json_response(post(conn, "/api/v1/runs/#{run.id}/cancel"), 409)
    end

    test "returns 404 for another tenant's run", %{conn: conn} do
      other_tenant = create_tenant()
      other_agent = create_agent(other_tenant)

      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: other_agent.id, tenant_id: other_tenant.id, trigger_type: "message",
          input: %{"user_message" => "hello"}, status: "running"
        })

      assert json_response(post(conn, "/api/v1/runs/#{run.id}/cancel"), 404)
      assert Norns.Runs.get_run!(run.id).status == "running"
    end
  end

  describe "GET /api/v1/runs/:id/events" do
    test "returns event log", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{},
          status: "running"
        })

      Norns.Runs.append_event(run, %{event_type: "run_started", source: "system"})

      Norns.Runs.append_event(run, %{
        event_type: "llm_request",
        source: "system",
        payload: %{"step" => 1, "message_count" => 1}
      })

      conn = get(conn, "/api/v1/runs/#{run.id}/events")
      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 2
      assert Enum.map(events, & &1["event_type"]) == ["run_started", "llm_request"]
    end
  end

  describe "GET /api/v1/runs/:id/summary" do
    test "returns a trace summary", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: agent.id,
          tenant_id: tenant.id,
          trigger_type: "message",
          input: %{},
          status: "completed"
        })

      Norns.Runs.append_event(run, %{
        event_type: "tool_call",
        source: "system",
        payload: %{
          "tool_call_id" => "c1",
          "name" => "search_docs",
          "arguments" => %{"query" => "refunds"},
          "step" => 1
        }
      })

      Norns.Runs.append_event(run, %{
        event_type: "tool_result",
        source: "system",
        payload: %{
          "tool_call_id" => "c1",
          "name" => "search_docs",
          "content" => "3 results",
          "is_error" => false,
          "step" => 1
        }
      })

      conn = get(conn, "/api/v1/runs/#{run.id}/summary")
      assert %{"data" => summary} = json_response(conn, 200)

      assert summary["run_id"] == run.id
      assert summary["reason"] == "completed"
      assert summary["counters"]["tool_calls"] == 1
      assert [%{"call" => call}] = summary["timeline"]
      assert call =~ "search_docs"
    end

    test "returns 404 for another tenant's run", %{conn: conn} do
      other = create_tenant(%{slug: "other-summary"})
      other_agent = create_agent(other)

      {:ok, run} =
        Norns.Runs.create_run(%{
          agent_id: other_agent.id,
          tenant_id: other.id,
          trigger_type: "message",
          input: %{},
          status: "completed"
        })

      conn = get(conn, "/api/v1/runs/#{run.id}/summary")
      assert json_response(conn, 404)
    end
  end

  describe "authentication" do
    test "returns 401 without token" do
      conn = build_conn() |> get("/api/v1/runs/123")
      assert json_response(conn, 401)
    end

    test "returns 401 with invalid token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer invalid-token")
        |> get("/api/v1/runs/123")

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/v1/runs/:id/fork" do
    test "forks a run and rejects bad steps", %{conn: conn, tenant: tenant, agent: agent} do
      {:ok, run} =
        Norns.Runs.create_run(%{agent_id: agent.id, tenant_id: tenant.id, trigger_type: "message", input: %{"user_message" => "hi"}, status: "completed"})

      {:ok, _} = Norns.Runs.append_event(run, %{event_type: "run_started", source: "system", payload: %{}})
      {:ok, _} = Norns.Runs.append_event(run, %{event_type: "llm_response", source: "system", payload: %{"content" => "done", "finish_reason" => "stop", "usage" => %{}, "step" => 1}})

      Norns.TestWorker.LLM.set_responses([%{content: [%{"type" => "text", "text" => "forked"}], stop_reason: "end_turn"}])

      conn2 = post(conn, "/api/v1/runs/#{run.id}/fork", %{"step" => 1, "message" => "again"})
      assert %{"status" => "accepted", "run_id" => fork_id, "agent_id" => agent_id, "data" => %{"trigger_type" => "fork"}} = json_response(conn2, 201)
      assert agent_id == agent.id
      assert Norns.Runs.get_run!(fork_id).input["fork"] == %{"run_id" => run.id, "step" => 1}

      assert %{"error" => error} = json_response(post(conn, "/api/v1/runs/#{run.id}/fork", %{"step" => 5}), 422)
      assert error =~ "beyond"
    end
  end
end
