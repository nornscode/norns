defmodule Norns.Hooks do
  @moduledoc """
  Inbound webhooks: token-addressed ingress that starts runs.

  Management is tenant-scoped CRUD; ingest (`handle_delivery/4`) is the
  public path — look up by token, verify the provider signature against the
  raw body, extract the message and conversation key, start a run with
  `trigger_type: "webhook"`.
  """

  import Ecto.Query

  alias Norns.Repo
  alias Norns.Hooks.{Hook, Signature}
  alias Norns.Agents.Registry

  # -- CRUD (tenant-scoped) --

  def list_hooks(tenant_id) do
    Repo.all(from h in Hook, where: h.tenant_id == ^tenant_id, order_by: h.id)
  end

  def get_hook(tenant_id, id) do
    Repo.get_by(Hook, id: id, tenant_id: tenant_id)
  end

  def create_hook(attrs) do
    %Hook{}
    |> Hook.changeset(attrs)
    |> Norns.Agents.validate_agent_in_tenant()
    |> Repo.insert()
  end

  def update_hook(%Hook{} = hook, attrs) do
    hook
    |> Hook.changeset(attrs)
    |> Norns.Agents.validate_agent_in_tenant()
    |> Repo.update()
  end

  def delete_hook(%Hook{} = hook) do
    Repo.delete(hook)
  end

  # -- Ingest --

  @doc """
  Handle a webhook delivery addressed by `token`.

  Returns `{:ok, run_id}`, or `{:error, code}` where code maps to a response:
  `:not_found` (unknown or disabled token — indistinguishable on purpose),
  `:busy` (the mapped conversation has a run in flight; the provider should
  retry), or a signature error string from `Norns.Hooks.Signature`.
  """
  def handle_delivery(token, payload, raw_body, headers) when is_binary(token) do
    case Repo.get_by(Hook, token: token) do
      %Hook{enabled: true} = hook ->
        with :ok <- Signature.verify(hook, raw_body, headers) do
          fire(hook, payload)
        end

      # Disabled reads the same as unknown — a token that stops working
      # reveals nothing about whether it ever existed.
      _ ->
        {:error, :not_found}
    end
  end

  defp fire(hook, payload) do
    message = extract_message(hook, payload)

    opts = [trigger_type: "webhook"]

    opts =
      case extract_path(payload, hook.conversation_key_path) do
        value when is_binary(value) and value != "" ->
          # Prefix keeps hook-derived keys from colliding with client keys.
          Keyword.put(opts, :conversation_key, "hook_#{hook.id}_#{value}")

        _ ->
          opts
      end

    Registry.send_message(hook.tenant_id, hook.agent_id, message, opts)
  end

  defp extract_message(hook, payload) do
    case extract_path(payload, hook.message_path) do
      value when is_binary(value) and value != "" -> value
      value when is_number(value) -> to_string(value)
      _ -> Jason.encode!(payload, pretty: true)
    end
  end

  # Dot-path into a (string-keyed) JSON payload: "event.channel" etc.
  defp extract_path(_payload, nil), do: nil
  defp extract_path(_payload, ""), do: nil

  defp extract_path(payload, path) when is_map(payload) do
    get_in(payload, String.split(path, "."))
  rescue
    # get_in raises on non-map intermediates (e.g. path into a list/string).
    _ -> nil
  end

  defp extract_path(_payload, _path), do: nil
end
