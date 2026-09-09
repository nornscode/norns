defmodule Norns.Runtime.Content do
  @moduledoc """
  The opaque-content principle.

  The orchestrator routes on the **envelope** and never reads, transforms, or
  generates **content**. Content is whatever a worker or a human wrote and an
  LLM will read: message text, tool arguments, tool results, system prompts,
  human questions and answers, run output. The envelope is what the state
  machine needs: roles, kinds, tool names, tool-call ids, steps, usage, stop
  reasons, error classes, agent names.

  A content position holds one of three things, and core treats all three
  the same way — store it, forward it, never look inside:

    * a string — plaintext written by a worker, a human, or a model
    * a structured map — tool arguments as the model produced them
    * an opaque block — content a worker encrypted with a key core does not
      hold: `%{"$enc" => "v1", "kid" => ..., "n" => ..., "ct" => ...}`

  Where core used to write prose for the model to read (a timer result, a
  denied tool, a sub-agent's outcome), the message now carries a `kind` and
  envelope `data`, and the LLM worker renders the prose. See
  `Norns.LLM.Format.render_message/1` for the reference rendering and
  `docs/plan-harness-e2e.md` for the design.
  """

  @doc "An opaque block: content encrypted by a worker with a key core does not hold."
  def opaque?(%{"$enc" => _}), do: true
  def opaque?(_), do: false

  @doc "Whether a value may sit in a content position."
  def valid?(value) when is_binary(value) or is_map(value), do: true
  def valid?(_), do: false

  @doc """
  Content headed for a string column (`runs.output`). Strings pass through; a
  map or opaque block is JSON-encoded so it survives the column type, and
  clients decode it. The column becomes JSONB when encryption ships (E2).
  """
  def to_column(value) when is_binary(value), do: value
  def to_column(nil), do: ""
  def to_column(value) when is_map(value), do: Jason.encode!(value)

  @doc """
  Content as text for a client that holds no key: the dashboard, a log line.
  An opaque block reads as `[encrypted]`; a structured map is shown encoded.
  """
  def to_text(value) when is_binary(value), do: value
  def to_text(nil), do: ""
  def to_text(%{"$enc" => _}), do: "[encrypted]"
  def to_text(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  def to_text(value), do: to_string(value)
end
