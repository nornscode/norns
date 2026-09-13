defmodule Norns.Agents.Messages do
  @moduledoc """
  The shape of a conversation's messages, in and out of storage.

  Two things need this and neither owns it: the agent process, building the
  history for the next step, and `Norns.Agents.Replay`, rebuilding that same
  history from the event log. It lives here so a message reloaded from
  Postgres and a message that never left memory are the same message.

  Content is passed through untouched — a string, a structured map, or an
  opaque block. What is normalised is the envelope around it: roles, keys,
  and the tool-linkage fields that let a result be paired back to the call
  it answers.
  """

  @doc "Messages as they came back from JSONB, in the in-memory shape."
  def normalize(messages) when is_list(messages), do: Enum.map(messages, &normalize_one/1)
  def normalize(_messages), do: []

  # In-memory messages already carry atom keys and the full neutral shape.
  defp normalize_one(%{role: _role, content: _content} = message), do: message

  # Messages reloaded from Postgres JSONB come back string-keyed. Rebuild them
  # with atom keys while preserving the tool-linkage fields (tool_calls on
  # assistant turns; tool_call_id/name/is_error on tool turns) — without these,
  # Anthropic rejects the replayed history since tool results can't be paired
  # back to their tool_use blocks.
  defp normalize_one(%{"role" => role} = m) do
    %{role: role, content: m["content"]}
    |> maybe_put(:tool_calls, m["tool_calls"])
    |> maybe_put(:tool_call_id, m["tool_call_id"])
    |> maybe_put(:name, m["name"])
    |> maybe_put(:is_error, m["is_error"])
    |> maybe_put(:kind, m["kind"])
    |> maybe_put(:data, m["data"])
    |> maybe_put(:run_id, m["run_id"])
  end

  @doc """
  The messages a run inherits from its `context`: a parent's history, and
  the parent's data as a turn of its own.
  """
  def from_context(nil), do: []

  def from_context(context) when is_map(context) do
    inherited = inherited_messages(context["messages"] || context[:messages])
    data = data_message(context["data"] || context[:data])
    inherited ++ data
  end

  def from_context(_), do: []

  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  defp inherited_messages(nil), do: []

  defp inherited_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} -> %{role: role, content: content}
      %{"role" => role, "content" => content} -> %{role: role, content: content}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp inherited_messages(_), do: []

  # The parent's data is forwarded as it came; the LLM worker renders the
  # preamble the model reads.
  defp data_message(nil), do: []
  defp data_message(data) when data == %{}, do: []

  defp data_message(data) when is_map(data) or is_binary(data) do
    [%{role: "user", kind: "inherited_context", content: data}]
  end

  defp data_message(_), do: []
end
