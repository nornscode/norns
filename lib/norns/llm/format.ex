defmodule Norns.LLM.Format do
  @moduledoc """
  Translates between the provider-neutral message format (used internally
  and on the wire) and provider-specific API formats (Anthropic, OpenAI, etc).

  ## Neutral format

  Messages:
    - %{role: "user", content: "text"}
    - %{role: "assistant", content: "text", tool_calls: [%{"id" => ..., "name" => ..., "arguments" => ...}]}
    - %{role: "tool", tool_call_id: "tc_1", name: "search", content: "result"}

  Tool definitions:
    - %{name: "search", description: "...", parameters: %{...}}

  Finish reasons: "stop", "tool_call", "length", "error"

  ## Kinds

  The orchestrator never writes prose for the model (`Norns.Runtime.Content`).
  Where it used to — a timer result, a denied tool, a sub-agent's outcome, a
  parent's inherited context — the message carries a `kind` plus envelope
  `data`, and the worker renders it with `render_message/1` before the
  provider call. Tenant content on such a message (a child's output, the
  inherited data) stays in `content`; only the structure is in `data`.

  Workers also compose the system prompt (`compose_system_prompt/1`) and
  decide the run's final output (`final_output/2`), because both need to
  read text.
  """

  # --- Worker-side rendering ---

  @compaction_instruction """
  Write a summary of the conversation so far for your own future reference. \
  You will continue the same task with only this summary and the most recent \
  messages, so keep every fact you would need: the task and its constraints, \
  decisions made and why, files and identifiers touched, what was tried and \
  failed, what remains to be done, and anything the user asked for that is not \
  finished. Fold in the earlier summary if there is one. Write prose or terse \
  notes, no preamble, no commentary about summarising.\
  """

  @doc """
  The system prompt for a `purpose: "compact"` task: the def's prompt (so the
  summary is written from the agent's point of view) plus the earlier summary.
  """
  @spec compose_compaction_prompt(map()) :: String.t()
  def compose_compaction_prompt(task) do
    prompt = task[:system_prompt] || task["system_prompt"] || ""
    summary = task[:summary] || task["summary"]

    if is_binary(summary) and summary != "" do
      prompt <> "\n\nSummary of earlier conversation: " <> summary
    else
      prompt
    end
  end

  @doc "The messages for a compaction call: the folded history, then the instruction."
  @spec compaction_messages(map()) :: [map()]
  def compaction_messages(task) do
    messages = task[:messages] || task["messages"] || []
    render_messages(messages) ++ [%{role: "user", content: @compaction_instruction}]
  end

  @doc "Render a kinded message to a plain-content message. Messages without a kind pass through."
  def render_message(msg) do
    case msg[:kind] || msg["kind"] do
      nil -> msg
      kind -> put_content(msg, render_kind(kind, msg[:data] || msg["data"] || %{}, msg[:content] || msg["content"]))
    end
  end

  def render_messages(messages), do: Enum.map(messages, &render_message/1)

  defp put_content(%{role: _} = msg, content), do: msg |> Map.put(:content, content) |> Map.drop([:kind, :data])
  defp put_content(msg, content), do: msg |> Map.put("content", content) |> Map.drop(["kind", "data"])

  defp render_kind("inherited_context", _data, content) do
    "[Inherited context from parent agent]\n" <> encode(content)
  end

  defp render_kind("timer_completed", _data, _content), do: "Timer completed."

  defp render_kind("tool_denied", data, _content) do
    "Tool '#{data["tool_name"]}' is not in this agent's allowed tools."
  end

  defp render_kind("subagent_denied", %{"reason" => "disabled"}, _content) do
    "This agent is not permitted to launch sub-agents."
  end

  defp render_kind("subagent_denied", %{"reason" => "max_depth"} = data, _content) do
    "Sub-agent nesting limit reached (max depth #{data["max_depth"]}). " <>
      "Do the work in this agent instead of delegating further."
  end

  defp render_kind("subagent_denied", data, _content) do
    "Agent '#{data["agent_name"]}' is not in this agent's allowed sub-agents."
  end

  defp render_kind("subagent_list_denied", _data, _content) do
    "Listing agents is not permitted for this agent."
  end

  defp render_kind("subagent_not_found", data, _content), do: "Agent '#{data["agent_name"]}' not found"
  defp render_kind("subagent_self", _data, _content), do: "Cannot launch self as a sub-agent"

  defp render_kind("subagent_missing", data, _content) do
    "Sub-agent run #{data["run_id"]} no longer exists, so its result cannot be recovered."
  end

  defp render_kind("subagent_launch_failed", data, _content) do
    "Failed to launch agent '#{data["agent_name"]}': #{data["reason"]}"
  end

  # The child's run id rides along with its text so the parent has a handle
  # to inspect *how* the child got there, not just what it said.
  defp render_kind("subagent_completed", data, content) do
    encode(%{"run_id" => data["run_id"], "status" => "completed", "output" => content || ""})
  end

  defp render_kind("subagent_failed", data, content) do
    encode(%{"run_id" => data["run_id"], "status" => "failed", "error" => content || ""})
  end

  defp render_kind("list_agents", data, _content), do: encode(data["agents"] || [])
  defp render_kind(_unknown, data, content) when content in [nil, ""], do: encode(data)
  defp render_kind(_unknown, _data, content), do: content

  defp encode(value) when is_binary(value), do: value
  defp encode(value), do: Jason.encode!(value)

  @doc """
  The system prompt the model sees: the def's prompt verbatim, then the
  conversation summary and the date the orchestrator put in the task envelope.
  """
  def compose_system_prompt(task) do
    prompt = task[:system_prompt] || task["system_prompt"] || ""
    summary = task[:summary] || task["summary"]
    date = task[:date] || task["date"]

    prompt
    |> then(fn p -> if is_binary(summary) and summary != "", do: p <> "\n\nSummary of earlier conversation: " <> summary, else: p end)
    |> then(fn p -> if date, do: p <> "\n\nCurrent date: #{date}.", else: p end)
  end

  @doc """
  The run's output when the model stops. A turn can produce substantive text
  alongside a tool call and then end with an empty "stop" turn; fall back to
  the last non-empty assistant text rather than losing it.
  """
  def final_output(messages, content) do
    text = if is_binary(content), do: content, else: ""

    if String.trim(text) == "" do
      messages
      |> Enum.reverse()
      |> Enum.find_value(text, fn msg ->
        case {msg_role(msg), msg[:content] || msg["content"]} do
          {"assistant", c} when is_binary(c) -> if String.trim(c) == "", do: nil, else: c
          _ -> nil
        end
      end)
    else
      text
    end
  end

  # --- Neutral → Anthropic API ---

  @doc "Convert neutral messages to Anthropic API format. Kinded messages are rendered first."
  def to_anthropic_messages(messages) do
    messages
    |> render_messages()
    |> Enum.chunk_by(fn msg -> msg_role(msg) == "tool" end)
    |> Enum.flat_map(&convert_chunk_to_anthropic/1)
  end

  @doc "Convert neutral tool definitions to Anthropic format."
  def to_anthropic_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "name" => tool[:name] || tool["name"],
        "description" => tool[:description] || tool["description"],
        "input_schema" => tool[:parameters] || tool["parameters"] || tool[:input_schema] || tool["input_schema"] || %{}
      }
    end)
  end

  @doc "Convert Anthropic API response to neutral format."
  def from_anthropic_response(response) do
    content_blocks = response["content"] || []

    text =
      content_blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    tool_calls =
      content_blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn block ->
        %{
          "id" => block["id"],
          "name" => block["name"],
          "arguments" => block["input"]
        }
      end)

    finish_reason =
      case response["stop_reason"] do
        "end_turn" -> "stop"
        "tool_use" -> "tool_call"
        "max_tokens" -> "length"
        other -> other || "stop"
      end

    result = %{
      "content" => text,
      "finish_reason" => finish_reason,
      "usage" => response["usage"] || %{}
    }

    if tool_calls != [] do
      Map.put(result, "tool_calls", tool_calls)
    else
      result
    end
  end

  # --- Internal helpers ---

  defp convert_chunk_to_anthropic(msgs) do
    case msgs do
      [%{role: "tool"} | _] = tool_msgs ->
        convert_tool_chunk(tool_msgs)

      [%{"role" => "tool"} | _] = tool_msgs ->
        convert_tool_chunk(tool_msgs)

      other_msgs ->
        Enum.map(other_msgs, &convert_msg_to_anthropic/1)
    end
  end

  defp convert_tool_chunk(tool_msgs) do
    tool_results =
      Enum.map(tool_msgs, fn msg ->
        result = %{
          "type" => "tool_result",
          "tool_use_id" => msg[:tool_call_id] || msg["tool_call_id"],
          "content" => msg[:content] || msg["content"]
        }

        if msg[:is_error] || msg["is_error"] do
          Map.put(result, "is_error", true)
        else
          result
        end
      end)

    [%{"role" => "user", "content" => tool_results}]
  end

  defp convert_msg_to_anthropic(%{role: "assistant"} = msg) do
    tool_calls = msg[:tool_calls] || msg["tool_calls"] || []
    text = msg[:content] || msg["content"] || ""

    content =
      if tool_calls != [] do
        text_block = if text != "", do: [%{"type" => "text", "text" => text}], else: []

        tool_blocks =
          Enum.map(tool_calls, fn tc ->
            %{
              "type" => "tool_use",
              "id" => tc["id"],
              "name" => tc["name"],
              "input" => tc["arguments"]
            }
          end)

        text_block ++ tool_blocks
      else
        text
      end

    %{"role" => "assistant", "content" => content}
  end

  defp convert_msg_to_anthropic(%{role: role, content: content}) do
    %{"role" => role, "content" => content}
  end

  defp convert_msg_to_anthropic(%{"role" => role, "content" => content} = msg) do
    if msg["tool_calls"] do
      convert_msg_to_anthropic(%{role: role, content: content, tool_calls: msg["tool_calls"]})
    else
      %{"role" => role, "content" => content}
    end
  end

  defp msg_role(%{role: role}), do: role
  defp msg_role(%{"role" => role}), do: role
end
