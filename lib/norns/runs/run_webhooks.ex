defmodule Norns.Runs.RunWebhooks do
  @moduledoc """
  Run webhooks: tenant-scoped CRUD, and the delivery of run events to them.

  Delivery is the wake (`Norns.Workers.Wake`) pointed the other way: a signed
  `POST` with a JSON body, `Content-Type: application/json`, `X-Norns-Event`
  naming the event, and `X-Norns-Signature` from
  `Norns.Workers.HttpSignature`. The body is

      {"type": "run.waiting", "run_id": 42, "agent_id": 7, "conversation_id": 9,
       "trigger_type": "message", "status": "waiting",
       "question": "Proceed?", "tool_call_id": "toolu_..."}

  with `output` in place of the question for `run.completed` and `error` for
  `run.failed`. Nothing is read from the response beyond its status. Each
  delivery runs in its own task under `Norns.TaskSupervisor`; a transport
  failure or a 5xx is retried a few times with backoff, since a receiver that
  sleeps between events can look refused while it starts.

  The orchestrator calls `notify/4` from the agent process's broadcast, so
  the events here are exactly the moments the dashboard and the agent
  channel see — no second source of truth about what a run is doing.

  Set `:norns, :run_webhook_req_options` to add Req options, which tests use
  to route the request to a plug.
  """

  import Ecto.Query

  require Logger

  alias Norns.Repo
  alias Norns.Runs.RunWebhook
  alias Norns.Workers.HttpSignature

  @receive_timeout_ms :timer.seconds(60)

  # ----------------------------------------------------------------- CRUD

  def list_run_webhooks(tenant_id) do
    Repo.all(from w in RunWebhook, where: w.tenant_id == ^tenant_id, order_by: w.id)
  end

  def get_run_webhook(tenant_id, id) do
    Repo.get_by(RunWebhook, id: id, tenant_id: tenant_id)
  end

  def create_run_webhook(attrs) do
    %RunWebhook{} |> RunWebhook.changeset(attrs) |> Repo.insert()
  end

  def update_run_webhook(%RunWebhook{} = webhook, attrs) do
    webhook |> RunWebhook.changeset(attrs) |> Repo.update()
  end

  def delete_run_webhook(%RunWebhook{} = webhook) do
    Repo.delete(webhook)
  end

  @doc "Enabled webhooks of a tenant subscribed to `event`."
  def subscribed(tenant_id, event) do
    Repo.all(
      from w in RunWebhook,
        where: w.tenant_id == ^tenant_id and w.enabled == true and ^event in w.events,
        order_by: w.id
    )
  end

  # ------------------------------------------------------------- delivery

  @doc """
  Called by the agent process on every broadcast. Turns the three broadcasts
  that are run state changes into deliveries and ignores the rest. `run` is
  the run struct as of the broadcast; `payload` is the broadcast payload.
  """
  def notify(_tenant_id, nil, _event, _payload), do: :ok

  def notify(tenant_id, run, event, payload) do
    case event_type(event) do
      nil ->
        :ok

      type ->
        # One query per state change. State changes are rare next to tool
        # calls, and a cache would need invalidating from the API.
        case subscribed(tenant_id, type) do
          [] -> :ok
          webhooks -> deliver_all_async(webhooks, type, body(type, run, payload))
        end
    end
  end

  defp event_type(:waiting_for_user), do: "run.waiting"
  defp event_type(:completed), do: "run.completed"
  defp event_type(:error), do: "run.failed"
  defp event_type(_), do: nil

  defp body(type, run, payload) do
    base = %{
      type: type,
      run_id: run.id,
      agent_id: run.agent_id,
      conversation_id: run.conversation_id,
      trigger_type: run.trigger_type,
      status: status(type)
    }

    case type do
      "run.waiting" ->
        Map.merge(base, %{question: payload[:question], tool_call_id: payload[:tool_call_id]})

      "run.completed" ->
        Map.put(base, :output, payload[:output])

      "run.failed" ->
        Map.put(base, :error, payload[:error])
    end
  end

  defp status("run.waiting"), do: "waiting"
  defp status("run.completed"), do: "completed"
  defp status("run.failed"), do: "failed"

  defp deliver_all_async(webhooks, type, body) do
    Enum.each(webhooks, fn webhook ->
      Task.Supervisor.start_child(Norns.TaskSupervisor, fn -> deliver(webhook, type, body) end)
    end)

    :ok
  end

  @doc """
  Deliver one event synchronously. Returns `:ok`, `{:error, {:status, n}}`
  for a non-2xx answer, or `{:error, exception}`.
  """
  def deliver(%RunWebhook{} = webhook, type, body) when is_map(body) do
    json = Jason.encode!(body)

    headers = [
      {"content-type", "application/json"},
      {"x-norns-event", type},
      {HttpSignature.header_name(), HttpSignature.sign(webhook.secret, json)}
    ]

    opts =
      [
        url: webhook.url,
        body: json,
        headers: headers,
        receive_timeout: @receive_timeout_ms,
        retry: &retry?/2,
        max_retries: 3,
        retry_log_level: :debug
      ] ++ Application.get_env(:norns, :run_webhook_req_options, [])

    case Req.post(Req.new(opts)) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Run webhook #{webhook.id} (#{type}) answered HTTP #{status}")
        {:error, {:status, status}}

      {:error, exception} ->
        Logger.warning(
          "Run webhook #{webhook.id} (#{type}) failed: #{Exception.message(exception)}"
        )

        {:error, exception}
    end
  end

  @doc "A sample event for checking a receiver end to end."
  def test_body do
    %{type: "run.test", run_id: nil, agent_id: nil, conversation_id: nil, trigger_type: nil, status: "test"}
  end

  defp retry?(_request, %Req.TransportError{reason: :timeout}), do: false
  defp retry?(_request, %Req.TransportError{}), do: true
  defp retry?(_request, %Req.Response{status: status}) when status in [502, 503, 504], do: true
  defp retry?(_request, _response_or_exception), do: false
end
