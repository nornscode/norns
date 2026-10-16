defmodule Norns.WakeStub do
  @moduledoc """
  Catches the wakes `Norns.Workers.Wake` sends during a test.

  The test config points wakes at a Req.Test plug. One stub is installed for
  the whole suite (`install_default/0`, from `test_helper.exs`, in shared
  mode: wakes run in supervised tasks, not the test process). It forwards
  each request to whichever test called `install/1` last, as
  `{:wake, %{worker_id:, body:, signature:}}`, answering the status that
  test asked for — or swallows it when no test is listening, since a
  re-wake timer from one test can fire after it has ended. Tests match
  wakes on their own `worker_id`, never on `_`, for the same reason.
  """

  @listener {__MODULE__, :listener}

  @doc "Route wakes to this test process for the rest of the test."
  def install(status \\ 200) do
    :persistent_term.put(@listener, {self(), status})
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase(@listener) end)
    :ok
  end

  @doc "Install the suite-wide stub. Call once, before tests run."
  def install_default do
    Req.Test.set_req_test_to_shared(%{})

    Req.Test.stub(Norns.Workers.Wake, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      status =
        case :persistent_term.get(@listener, nil) do
          {pid, status} when is_pid(pid) ->
            send(pid, {
              :wake,
              %{
                worker_id: conn |> Plug.Conn.get_req_header("x-norns-worker-id") |> List.first(),
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
