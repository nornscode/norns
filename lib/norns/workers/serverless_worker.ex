defmodule Norns.Workers.ServerlessWorker do
  @moduledoc """
  A worker that is not running until Norns wakes it.

  An ordinary worker holds a WebSocket open and is pushed tasks, so it has to
  be a running process. A serverless worker is the same worker with a wake
  URL in front of it: when a task has no connected worker to go to, Norns
  POSTs a signed wake to the URL, the platform starts the function or
  container, the worker connects over the normal `/worker` socket, and the
  queued task flushes to it like any reconnect. When it has been idle for a
  while it drains and disconnects, and the platform puts it back to sleep.

  Nothing about the task protocol changes — the wake is the only new message,
  and it carries no task. What does change is that a sleeping worker cannot
  be asked what it offers, so its `tools` and `capabilities` are declared
  here. The registry advertises them to agents while the worker is asleep and
  uses them to decide which sleeping worker a task should wake.

  `secret` is server-generated and shown once, on create; every wake carries
  an HMAC under it (`Norns.Workers.HttpSignature`) so the URL can refuse
  anything that is not Norns.

  Serverless workers have no gard: a function that may start anywhere has no
  filesystem to be affine to.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @capabilities ~w(llm tools)

  schema "serverless_workers" do
    field :worker_id, :string
    field :wake_url, :string
    field :secret, :string
    field :tools, {:array, :map}, default: []
    field :capabilities, {:array, :string}, default: ["tools"]
    field :enabled, :boolean, default: true

    belongs_to :tenant, Norns.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(worker, attrs) do
    worker
    |> cast(attrs, [:tenant_id, :worker_id, :wake_url, :tools, :capabilities, :enabled])
    |> validate_required([:tenant_id, :worker_id, :wake_url])
    |> validate_url()
    |> validate_tools()
    |> validate_subset(:capabilities, @capabilities)
    |> validate_length(:capabilities, min: 1)
    |> put_secret()
    |> unique_constraint(:worker_id, name: :serverless_workers_tenant_id_worker_id_index)
  end

  @doc "Tool names this worker declares."
  def tool_names(%__MODULE__{tools: tools}), do: Enum.map(tools, & &1["name"])

  defp validate_url(changeset) do
    validate_change(changeset, :wake_url, fn :wake_url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [wake_url: "must be an http(s) URL"]
      end
    end)
  end

  # Same shape the channel join validates: name, description, input_schema.
  defp validate_tools(changeset) do
    validate_change(changeset, :tools, fn :tools, tools ->
      if Enum.all?(tools, &valid_tool?/1),
        do: [],
        else: [tools: "each tool needs name, description and input_schema"]
    end)
  end

  defp valid_tool?(%{"name" => name, "description" => description, "input_schema" => schema})
       when is_binary(name) and name != "" and is_binary(description) and is_map(schema),
       do: true

  defp valid_tool?(_), do: false

  # Never client-supplied: the worker gets it from the create response.
  defp put_secret(changeset) do
    case get_field(changeset, :secret) do
      nil ->
        put_change(
          changeset,
          :secret,
          :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        )

      _ ->
        changeset
    end
  end
end
