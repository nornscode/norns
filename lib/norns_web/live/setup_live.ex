defmodule NornsWeb.SetupLive do
  use NornsWeb, :live_view

  alias Norns.Tenants

  @impl true
  def mount(_params, session, socket) do
    # If already authenticated, go to dashboard
    if session["tenant_id"] && Norns.Tenants.list_tenants() != [] do
      {:ok, push_navigate(socket, to: "/")}
    else
      {:ok,
       assign(socket,
         current_tenant: nil,
         step: :form,
         name: "",
         anthropic_key: "",
         created_tenant: nil,
         api_key: nil,
         error: nil
       )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-20">
      <h1 class="text-2xl font-bold text-white mb-2">norns</h1>
      <p class="text-sm text-gray-500 mb-8">Durable agent runtime on BEAM</p>

      <%= if @step == :form do %>
        <div class="bg-gray-900 border border-gray-800 rounded p-6">
          <h2 class="text-lg text-white mb-4">Create your first tenant</h2>

          <%= if @error do %>
            <div class="bg-red-900/30 border border-red-800 text-red-300 px-3 py-2 rounded mb-4 text-sm">
              <%= @error %>
            </div>
          <% end %>

          <form phx-submit="create_tenant" class="space-y-4">
            <div>
              <label class="text-xs text-gray-400 block mb-1">Tenant name</label>
              <input type="text" name="name" value={@name} required
                placeholder="My Organization"
                class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-gray-500" />
            </div>
            <div>
              <label class="text-xs text-gray-400 block mb-1">Anthropic API key <span class="text-gray-600">(optional)</span></label>
              <input type="text" name="anthropic_key" value={@anthropic_key}
                placeholder="sk-ant-..."
                class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-gray-500" />
              <p class="text-xs text-gray-600 mt-1">Used for LLM calls. Can be added later.</p>
            </div>
            <button type="submit"
              class="w-full bg-white text-gray-950 font-medium text-sm py-2 rounded hover:bg-gray-200">
              Create tenant
            </button>
          </form>
        </div>
      <% end %>

      <%= if @step == :done do %>
        <div class="bg-gray-900 border border-gray-800 rounded p-6">
          <h2 class="text-lg text-white mb-4">Tenant created</h2>

          <div class="space-y-4">
            <div>
              <label class="text-xs text-gray-400 block mb-1">Tenant</label>
              <div class="text-sm text-white"><%= @created_tenant.name %></div>
            </div>

            <div>
              <label class="text-xs text-gray-400 block mb-1">Your API key</label>
              <div class="bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-green-400 font-mono break-all">
                <%= @api_key %>
              </div>
              <p class="text-xs text-gray-500 mt-1">
                Save this — it won't be shown again. Use it for API access and to log in to the dashboard.
              </p>
            </div>

            <a href={"/?token=#{@api_key}"}
              class="block text-center w-full bg-white text-gray-950 font-medium text-sm py-2 rounded hover:bg-gray-200">
              Go to dashboard
            </a>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("create_tenant", %{"name" => name} = params, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, error: "Name is required")}
    else
      slug = __MODULE__.Slug.slugify(name)
      api_key = Tenants.generate_api_key()
      anthropic_key = String.trim(params["anthropic_key"] || "")

      api_keys =
        %{"norns" => api_key}
        |> then(fn keys ->
          if anthropic_key != "", do: Map.put(keys, "anthropic", anthropic_key), else: keys
        end)

      case Tenants.create_tenant(%{name: name, slug: slug, api_keys: api_keys}) do
        {:ok, tenant} ->
          {:noreply, assign(socket, step: :done, created_tenant: tenant, api_key: api_key, error: nil)}

        {:error, changeset} ->
          error =
            changeset
            |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
            |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)

          {:noreply, assign(socket, error: error)}
      end
    end
  end

  # Simple slug generation — no external dep needed
  defmodule Slug do
    def slugify(str) do
      base =
        str
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9\s-]/, "")
        |> String.replace(~r/\s+/, "-")
        |> String.trim("-")

      base = if base == "", do: "tenant", else: base

      # Append unique suffix to avoid conflicts
      "#{base}-#{System.unique_integer([:positive])}"
    end
  end
end
