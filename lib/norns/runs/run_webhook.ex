defmodule Norns.Runs.RunWebhook do
  @moduledoc """
  A URL that hears about run state changes.

  Three moments in a run's life have no outbound signal: it parks on an
  `ask_human` question, it completes, it fails. A client that needs to act on
  them — a chat channel that posts the question and relays the output — can
  only poll for them, which keeps it awake. A run webhook is the poll turned
  into a push: Norns POSTs a signed event to the URL at each of those
  moments, and the receiver can be a function that sleeps in between.

  `events` is the subset of `run.waiting`, `run.completed` and `run.failed`
  the URL wants. `secret` is server-generated and shown once, on create;
  every delivery carries an HMAC under it (`Norns.Workers.HttpSignature`,
  the same scheme as serverless-worker wakes), so the URL can refuse anything
  that is not Norns.

  Tenant-scoped, like everything else. The payload carries the run's
  envelope and the content of the moment (the question, the output, the
  error message), the same content the API returns for the run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @events ~w(run.waiting run.completed run.failed)

  schema "run_webhooks" do
    field :url, :string
    field :secret, :string
    field :events, {:array, :string}, default: @events
    field :enabled, :boolean, default: true

    belongs_to :tenant, Norns.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every event a run webhook can subscribe to."
  def events, do: @events

  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:tenant_id, :url, :events, :enabled])
    |> validate_required([:tenant_id, :url])
    |> validate_url()
    |> validate_subset(:events, @events)
    |> validate_length(:events, min: 1)
    |> put_secret()
  end

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [url: "must be an http(s) URL"]
      end
    end)
  end

  # Never client-supplied: the receiver gets it from the create response.
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
