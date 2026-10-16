defmodule Norns.Runs.RunWebhooksTest do
  use Norns.DataCase, async: false

  alias Norns.Runs.{RunWebhook, RunWebhooks}
  alias Norns.Workers.HttpSignature

  setup do
    Norns.RunWebhookStub.install()
    tenant = create_tenant()
    agent = create_agent(tenant)

    {:ok, run} =
      Norns.Runs.create_run(%{
        agent_id: agent.id,
        tenant_id: tenant.id,
        trigger_type: "schedule",
        input: %{"user_message" => "[scheduled] morning brief"},
        status: "running"
      })

    %{tenant: tenant, agent: agent, run: run}
  end

  defp create(tenant, attrs \\ %{}) do
    {:ok, webhook} =
      RunWebhooks.create_run_webhook(
        Map.merge(%{tenant_id: tenant.id, url: "https://channel.example.com/norns/events"}, attrs)
      )

    webhook
  end

  test "create generates a secret and subscribes to every event by default", %{tenant: tenant} do
    webhook = create(tenant)
    assert String.length(webhook.secret) == 43
    assert webhook.events == RunWebhook.events()
    assert webhook.enabled
  end

  test "validates url and events", %{tenant: tenant} do
    assert {:error, changeset} =
             RunWebhooks.create_run_webhook(%{tenant_id: tenant.id, url: "ftp://nope"})

    assert Keyword.has_key?(changeset.errors, :url)

    assert {:error, changeset} =
             RunWebhooks.create_run_webhook(%{
               tenant_id: tenant.id,
               url: "https://x.test",
               events: ["run.started"]
             })

    assert Keyword.has_key?(changeset.errors, :events)

    assert {:error, changeset} =
             RunWebhooks.create_run_webhook(%{tenant_id: tenant.id, url: "https://x.test", events: []})

    assert Keyword.has_key?(changeset.errors, :events)
  end

  test "subscribed/2 filters by tenant, event and enabled", %{tenant: tenant} do
    all = create(tenant)
    waiting_only = create(tenant, %{events: ["run.waiting"]})
    _disabled = create(tenant, %{enabled: false})
    _other_tenant = create(create_tenant())

    assert Enum.map(RunWebhooks.subscribed(tenant.id, "run.waiting"), & &1.id) ==
             [all.id, waiting_only.id]

    assert Enum.map(RunWebhooks.subscribed(tenant.id, "run.completed"), & &1.id) == [all.id]
  end

  test "notify delivers run.waiting with the question, signed", %{tenant: tenant, run: run} do
    webhook = create(tenant)

    :ok =
      RunWebhooks.notify(tenant.id, run, :waiting_for_user, %{
        question: "Proceed?",
        tool_call_id: "toolu_1"
      })

    assert_receive {:run_webhook, %{event: "run.waiting", body: body, signature: sig}}, 2000
    assert :ok = HttpSignature.verify(webhook.secret, body, sig)

    assert %{
             "type" => "run.waiting",
             "run_id" => run_id,
             "agent_id" => agent_id,
             "trigger_type" => "schedule",
             "status" => "waiting",
             "question" => "Proceed?",
             "tool_call_id" => "toolu_1"
           } = Jason.decode!(body)

    assert run_id == run.id
    assert agent_id == run.agent_id
  end

  test "notify delivers run.completed with the output and run.failed with the error", %{
    tenant: tenant,
    run: run
  } do
    create(tenant)

    :ok = RunWebhooks.notify(tenant.id, run, :completed, %{output: "Good morning."})
    assert_receive {:run_webhook, %{event: "run.completed", body: body}}, 2000
    assert %{"type" => "run.completed", "status" => "completed", "output" => "Good morning."} = Jason.decode!(body)

    :ok = RunWebhooks.notify(tenant.id, run, :error, %{error: "boom"})
    assert_receive {:run_webhook, %{event: "run.failed", body: body}}, 2000
    assert %{"type" => "run.failed", "status" => "failed", "error" => "boom"} = Jason.decode!(body)
  end

  test "notify ignores broadcasts that are not state changes, and runs with no webhook", %{
    tenant: tenant,
    run: run
  } do
    create(tenant)
    :ok = RunWebhooks.notify(tenant.id, run, :tool_call, %{name: "now", arguments: %{}})
    :ok = RunWebhooks.notify(tenant.id, run, :llm_response, %{})
    :ok = RunWebhooks.notify(tenant.id, nil, :completed, %{output: "x"})
    refute_receive {:run_webhook, _}, 300
  end

  test "an unsubscribed event is not delivered", %{tenant: tenant, run: run} do
    create(tenant, %{events: ["run.waiting"]})
    :ok = RunWebhooks.notify(tenant.id, run, :completed, %{output: "x"})
    refute_receive {:run_webhook, _}, 300
  end

  test "deliver reports a non-2xx answer", %{tenant: tenant} do
    Norns.RunWebhookStub.install(401)
    webhook = create(tenant)
    assert {:error, {:status, 401}} = RunWebhooks.deliver(webhook, "run.test", RunWebhooks.test_body())
    assert_receive {:run_webhook, %{event: "run.test"}}, 2000
  end

  test "a run parking on ask_human and completing delivers both events through the process", %{
    tenant: tenant,
    agent: agent
  } do
    webhook = create(tenant)

    Norns.TestWorker.LLM.set_responses([
      %{
        content: [
          %{
            "type" => "tool_use",
            "id" => "toolu_ask",
            "name" => "ask_human",
            "input" => %{"question" => "Proceed?"}
          }
        ],
        stop_reason: "tool_use"
      },
      %{content: [%{"type" => "text", "text" => "Done."}], stop_reason: "end_turn"}
    ])

    {:ok, run_id} =
      Norns.Agents.Registry.send_message(tenant.id, agent.id, "do the thing",
        conversation_key: "webhook-test"
      )

    assert_receive {:run_webhook, %{event: "run.waiting", body: body, signature: sig}}, 5000
    assert :ok = HttpSignature.verify(webhook.secret, body, sig)
    assert %{"run_id" => ^run_id, "question" => "Proceed?", "trigger_type" => "message"} = Jason.decode!(body)

    run = Norns.Runs.get_run!(run_id)
    :ok = Norns.Agents.Registry.reply_to_human(tenant.id, run, "yes")

    assert_receive {:run_webhook, %{event: "run.completed", body: body}}, 5000
    assert %{"run_id" => ^run_id, "output" => "Done."} = Jason.decode!(body)
  end

  test "a cancelled run is delivered as run.failed, with or without a process", %{
    tenant: tenant,
    agent: agent,
    run: orphan
  } do
    create(tenant)

    Norns.TestWorker.LLM.set_responses([
      %{
        content: [%{"type" => "tool_use", "id" => "toolu_ask", "name" => "ask_human", "input" => %{"question" => "Proceed?"}}],
        stop_reason: "tool_use"
      }
    ])

    {:ok, run_id} =
      Norns.Agents.Registry.send_message(tenant.id, agent.id, "do the thing", conversation_key: "cancel-webhook")

    assert_receive {:run_webhook, %{event: "run.waiting"}}, 5000

    assert {:ok, %{status: "failed"}} = Norns.Runs.Cancel.cancel(Norns.Runs.get_run!(run_id))
    assert_receive {:run_webhook, %{event: "run.failed", body: body}}, 5000
    assert %{"run_id" => ^run_id, "error" => "Cancelled by user", "status" => "failed"} = Jason.decode!(body)

    orphan_id = orphan.id
    assert {:ok, %{status: "failed"}} = Norns.Runs.Cancel.cancel(orphan)
    assert_receive {:run_webhook, %{event: "run.failed", body: body}}, 5000
    assert %{"run_id" => ^orphan_id, "error" => "Cancelled by user", "trigger_type" => "schedule"} = Jason.decode!(body)
  end
end
