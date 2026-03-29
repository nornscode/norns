defmodule NornsWeb.WorkerChannel do
  use NornsWeb, :channel

  require Logger
  alias Norns.Workers.WorkerRegistry

  @impl true
  def join("worker:lobby", params, socket) do
    with :ok <- validate_registration(params),
         {:ok, capabilities} <- parse_capabilities(Map.get(params, "capabilities")),
         tenant_id <- socket.assigns.tenant_id,
         :ok <- WorkerRegistry.register_worker(tenant_id, params["worker_id"], self(), params["tools"],
           capabilities: capabilities
         ) do
      socket = assign(socket, :worker_id, params["worker_id"])
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

  @impl true
  def terminate(_reason, socket) do
    if worker_id = socket.assigns[:worker_id] do
      WorkerRegistry.unregister_worker(socket.assigns.tenant_id, worker_id)
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
end
