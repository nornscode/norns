defmodule NornsWeb.WorkerChannel do
  use NornsWeb, :channel

  require Logger
  alias Norns.Gards
  alias Norns.Workers.WorkerRegistry

  @impl true
  def join("worker:lobby", params, socket) do
    with :ok <- validate_registration(params),
         {:ok, capabilities} <- parse_capabilities(Map.get(params, "capabilities")),
         tenant_id <- socket.assigns.tenant_id,
         {:ok, gard_id} <- claim_gard(tenant_id, params),
         :ok <- WorkerRegistry.register_worker(tenant_id, params["worker_id"], self(), params["tools"],
           capabilities: capabilities,
           gard: gard_id
         ) do
      socket =
        socket
        |> assign(:worker_id, params["worker_id"])
        |> assign(:gard, gard_id)

      {:ok, socket}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_in("tool_result", %{"task_id" => task_id} = payload, socket) do
    WorkerRegistry.deliver_result(task_id, payload)
    {:reply, :ok, socket}
  end

  # The worker is shutting down cleanly: stop sending it new tasks, let it
  # finish and report the ones it has, then it leaves. Without this a
  # supervisor restart (volund, a Fly reconciler) fails every in-flight task
  # and hands new ones to a worker that is about to exit.
  def handle_in("drain", _params, socket) do
    WorkerRegistry.drain_worker(socket.assigns.tenant_id, socket.assigns.worker_id)
    {:reply, :ok, socket}
  end

  # Ports arrive on the worker channel rather than a separate HTTP call —
  # reuses the worker's authentication, and the gard is inferred from the
  # connection (the worker declared it at join; re-specifying it per port
  # would be a class of mismatch errors).
  def handle_in("register_port", %{"internal_port" => _} = params, socket) do
    case socket.assigns[:gard] do
      nil ->
        {:reply, {:error, %{reason: "no gard"}}, socket}

      gard_id ->
        case Gards.register_port(gard_id, params) do
          {:ok, port} ->
            {:reply, {:ok, %{id: port.id, internal_port: port.internal_port, url: port.url}}, socket}

          {:error, changeset} ->
            {:reply, {:error, %{reason: format_errors(changeset)}}, socket}
        end
    end
  end

  @impl true
  def handle_info({:push_tool_task, task}, socket) do
    push(socket, "tool_task", task)
    {:noreply, socket}
  end

  def handle_info({:llm_task, task}, socket) do
    Logger.info("Pushing llm_task to worker #{socket.assigns[:worker_id]}, task_id=#{task[:task_id]}")
    push(socket, "llm_task", task)
    {:noreply, socket}
  end

  # The gard this worker claimed was destroyed — close the connection. This
  # runs terminate → unregister, which fails our in-flight tasks so waiting
  # agents get an error instead of a timeout.
  def handle_info(:gard_destroyed, socket) do
    push(socket, "gard_destroyed", %{})
    {:stop, :normal, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if worker_id = socket.assigns[:worker_id] do
      WorkerRegistry.unregister_worker(socket.assigns.tenant_id, worker_id, self())
    end

    :ok
  end

  defp validate_registration(%{"worker_id" => worker_id, "tools" => tools})
       when is_binary(worker_id) and worker_id != "" and is_list(tools) do
    case Enum.find(tools, &(not valid_tool_definition?(&1))) do
      nil -> :ok
      _invalid -> {:error, %{reason: "invalid_registration", code: "invalid_tools"}}
    end
  end

  defp validate_registration(_params) do
    {:error, %{reason: "invalid_registration", code: "missing_worker_id_or_tools"}}
  end

  defp valid_tool_definition?(%{"name" => name, "description" => description, "input_schema" => schema})
       when is_binary(name) and name != "" and is_binary(description) and is_map(schema),
       do: true

  defp valid_tool_definition?(_tool), do: false

  defp parse_capabilities(nil), do: {:ok, [:tools]}
  defp parse_capabilities(capabilities) when is_list(capabilities) do
    normalized =
      Enum.map(capabilities, fn
        "llm" -> :llm
        "tools" -> :tools
        :llm -> :llm
        :tools -> :tools
        other -> other
      end)

    if Enum.all?(normalized, &(&1 in [:llm, :tools])) do
      {:ok, Enum.uniq(normalized)}
    else
      {:error, %{reason: "invalid_registration", code: "invalid_capabilities"}}
    end
  end

  defp parse_capabilities(_other), do: {:error, %{reason: "invalid_registration", code: "invalid_capabilities"}}

  defp claim_gard(_tenant_id, %{"gard" => nil}), do: {:ok, nil}

  defp claim_gard(tenant_id, %{"gard" => gard_id} = params) when not is_nil(gard_id) do
    case normalize_gard_id(gard_id) do
      {:ok, gard_id} ->
        case Gards.claim(tenant_id, gard_id, params["claim_token"]) do
          :ok -> {:ok, gard_id}
          {:error, reason} -> {:error, %{reason: to_string(reason), code: "gard_claim_failed"}}
        end

      :error ->
        {:error, %{reason: "not_found", code: "gard_claim_failed"}}
    end
  end

  defp claim_gard(_tenant_id, _params), do: {:ok, nil}

  defp normalize_gard_id(id) when is_integer(id), do: {:ok, id}

  defp normalize_gard_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp normalize_gard_id(_), do: :error

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
