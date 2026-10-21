defmodule NornsWeb.WorkerSocket do
  use Phoenix.Socket

  channel "worker:*", NornsWeb.WorkerChannel

  # Both kinds of key open this socket. A scoped key carries its `ApiKey`
  # into the channel, where join checks the gard and capabilities against
  # it; a tenant key carries nil and joins as it always has.
  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Norns.Tenants.authenticate(token) do
      {:ok, tenant, key} -> {:ok, socket |> assign(:tenant_id, tenant.id) |> assign(:api_key, key)}
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "worker_socket:#{socket.assigns.tenant_id}"
end
