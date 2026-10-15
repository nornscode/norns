defmodule Norns.Workers.Wake do
  @moduledoc """
  Sends the wake for a serverless worker.

  A signed `POST` to the worker's `wake_url` with the body

      {"type": "wake", "worker_id": "<id>"}

  and the headers `Content-Type: application/json`, `X-Norns-Worker-Id` and
  `X-Norns-Signature` (see `Norns.Workers.HttpSignature`). The wake carries
  no task: the worker's job on receiving it is to connect to `/worker` as it
  normally would, and the queued work flushes to it on join.

  The response is not the result of anything, so Norns does not interpret
  it beyond logging. What Norns does do is keep the request open for as
  long as the worker holds it. On platforms that keep an instance alive
  only while it has an inbound request (Fly autostop, Cloud Run with
  request-scoped CPU, Lambda), the worker should hold the wake request
  open until it has gone idle and disconnected, then return. A worker on a
  platform that lets it answer at once and keep running may do that
  instead.

  Connection failures — refused, reset, DNS — are retried a few times with
  backoff, since a cold start can look like one from here. A timeout
  waiting for a response is not a failure and is not retried. Each wake
  runs in its own task under `Norns.TaskSupervisor`.

  Set `:norns, :wake_req_options` to add Req options, which tests use to
  route the request to a plug.
  """

  require Logger

  alias Norns.Workers.HttpSignature

  # How long Norns holds the wake request open at most. Long on purpose
  # (see the moduledoc); the worker returning sooner ends it sooner.
  @hold_ms :timer.hours(1)

  @doc "Wake asynchronously. Returns immediately."
  def wake_async(worker) do
    Task.Supervisor.start_child(Norns.TaskSupervisor, fn -> wake(worker) end)
    :ok
  end

  @doc "Wake synchronously. `worker` is `%{worker_id:, wake_url:, secret:}`."
  def wake(worker) do
    body = Jason.encode!(%{type: "wake", worker_id: worker.worker_id})

    headers = [
      {"content-type", "application/json"},
      {"x-norns-worker-id", worker.worker_id},
      {HttpSignature.header_name(), HttpSignature.sign(worker.secret, body)}
    ]

    opts =
      [
        url: worker.wake_url,
        body: body,
        headers: headers,
        receive_timeout: @hold_ms,
        retry: &retry?/2,
        max_retries: 3,
        retry_log_level: :debug
      ] ++ Application.get_env(:norns, :wake_req_options, [])

    case Req.post(Req.new(opts)) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Wake for serverless worker #{worker.worker_id} answered HTTP #{status}")
        {:error, {:status, status}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        # The worker held the request longer than we hold it. Not an error.
        :ok

      {:error, exception} ->
        Logger.warning(
          "Wake for serverless worker #{worker.worker_id} failed: #{Exception.message(exception)}"
        )

        {:error, exception}
    end
  end

  # Only transport failures before a response, never a slow response.
  defp retry?(_request, %Req.TransportError{reason: :timeout}), do: false
  defp retry?(_request, %Req.TransportError{}), do: true
  defp retry?(_request, %Req.Response{status: status}) when status in [502, 503, 504], do: true
  defp retry?(_request, _response_or_exception), do: false
end
