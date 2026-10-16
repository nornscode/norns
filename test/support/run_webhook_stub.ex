defmodule Norns.RunWebhookStub do
  @moduledoc """
  Catches the deliveries `Norns.Runs.RunWebhooks` sends during a test.

  Same arrangement as `Norns.WakeStub`: the test config points deliveries at
  a Req.Test plug, one stub is installed for the whole suite in shared mode
  (deliveries run in supervised tasks, not the test process), and it
  forwards each request to whichever test called `install/1` last as
  `{:run_webhook, %{event:, body:, signature:}}`, answering the status that
  test asked for. Strays from a finished test are swallowed.
  """

  @listener {__MODULE__, :listener}

  @doc "Route deliveries to this test process for the rest of the test."
  def install(status \\ 200) do
    :persistent_term.put(@listener, {self(), status})
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase(@listener) end)
    :ok
  end

  @doc "Install the suite-wide stub. Call once, before tests run."
  def install_default do
    Req.Test.stub(Norns.Runs.RunWebhooks, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      status =
        case :persistent_term.get(@listener, nil) do
          {pid, status} when is_pid(pid) ->
            send(pid, {
              :run_webhook,
              %{
                event: conn |> Plug.Conn.get_req_header("x-norns-event") |> List.first(),
                body: body,
                signature: conn |> Plug.Conn.get_req_header("x-norns-signature") |> List.first()
              }
            })

            status

          nil ->
            200
        end

      Plug.Conn.send_resp(conn, status, "")
    end)

    :ok
  end
end
