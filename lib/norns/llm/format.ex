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
  """

  # --- Neutral → Anthropic API ---

  @doc "Convert neutral messages to Anthropic API format."
  def to_anthropic_messages(messages) do
    messages
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
        # Group consecutive tool messages into a single user message with tool_result blocks
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

      other_msgs ->
        Enum.map(other_msgs, &convert_msg_to_anthropic/1)
    end
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
