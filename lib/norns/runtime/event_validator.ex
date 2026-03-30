defmodule Norns.Runtime.EventValidator do
  @moduledoc false

  alias Norns.Runtime.Event

  @schema_version 1

  @spec validate(map() | Event.t()) :: {:ok, map()} | {:error, map()}
  def validate(%Event{} = event) do
    validate(%{
      event_type: event.event_type,
      source: event.source,
      metadata: event.metadata,
      payload: event.payload
    })
  end

  def validate(attrs) when is_map(attrs) do
    event_type = event_type(attrs)
    source = Map.get(attrs, :source) || Map.get(attrs, "source") || "system"
    metadata = normalize_map(Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{})
    payload = normalize_map(Map.get(attrs, :payload) || Map.get(attrs, "payload") || %{})

    with :ok <- validate_source(source),
         {:ok, normalized_payload} <- normalize_payload(event_type, payload),
         :ok <- validate_payload(event_type, normalized_payload) do
      {:ok,
       %{
         event_type: event_type,
         source: source,
         metadata: metadata,
         payload: normalized_payload
       }}
    end
  end

  def schema_version, do: @schema_version

  defp event_type(attrs) do
    Map.get(attrs, :event_type) || Map.get(attrs, "event_type") || raise ArgumentError, "missing event_type"
  end

  defp validate_source(source) when source in ["system", "user", "worker"], do: :ok
  defp validate_source(_source), do: {:error, %{source: "is invalid"}}

  defp normalize_payload(_event_type, payload) do
    payload =
      case payload do
        %{"schema_version" => _} -> payload
        _ -> Map.put(payload, "schema_version", @schema_version)
      end

    {:ok, payload}
  end

  defp validate_payload(event_type, payload) do
    validators = validators_for(event_type)

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(payload) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validators_for(event_type) do
    case event_type do
      "run_started" -> [schema_version_validator()]
      "llm_request" -> [schema_version_validator(), required_integer("step"), required_integer("message_count"), optional_list("messages"), optional_string("system_prompt"), optional_string("model")]
      "llm_response" -> [schema_version_validator(), required_integer("step"), optional_string("content"), optional_string("finish_reason"), optional_list("tool_calls"), optional_map("usage")]
      "tool_call" -> [schema_version_validator(), required_string("tool_call_id"), required_string("name"), required_map("arguments"), required_integer("step"), optional_string("idempotency_key"), optional_boolean("side_effect")]
      "tool_duplicate" -> [schema_version_validator(), required_string("tool_call_id"), required_string("name"), required_string("idempotency_key"), required_integer("step"), required_integer("original_event_sequence"), required_string("resolution")]
      "tool_result" -> [schema_version_validator(), required_string("tool_call_id"), required_string("name"), required_field("content"), required_boolean("is_error"), required_integer("step"), optional_string("idempotency_key")]
      "checkpoint_saved" -> [schema_version_validator(), required_list("messages"), required_integer("step")]
      "run_failed" -> [schema_version_validator(), required_string("error"), required_string("error_class"), required_string("error_code"), required_string("retry_decision")]
      "run_completed" -> [schema_version_validator(), required_string("output")]
      "subagent_launched" -> [schema_version_validator(), required_string("tool_call_id"), required_string("child_agent_name"), required_string("child_run_id"), required_integer("step")]
      "waiting_for_timer" -> [schema_version_validator(), required_string("tool_call_id"), required_integer("seconds"), required_integer("step")]
      "waiting_for_user" -> [schema_version_validator(), required_string("question"), required_string("tool_call_id"), required_integer("step")]
      "user_response" -> [schema_version_validator(), required_string("content"), required_string("tool_call_id"), required_integer("step")]
      "retry" -> [schema_version_validator(), required_string("error"), required_integer("attempt"), required_integer("delay_ms"), required_integer("step"), required_string("error_class"), required_string("error_code"), required_string("retry_decision")]
      legacy when legacy in ["agent_started", "agent_completed", "agent_error", "checkpoint"] -> [schema_version_validator()]
      _ -> [schema_version_validator()]
    end
  end

  defp schema_version_validator do
    fn payload ->
      case payload["schema_version"] do
        @schema_version -> :ok
        _ -> {:error, %{payload: "schema_version is invalid"}}
      end
    end
  end

  defp required_string(key) do
    fn payload ->
      case payload[key] do
        value when is_binary(value) and value != "" -> :ok
        _ -> {:error, %{payload: "#{key} is required"}}
      end
    end
  end

  defp required_integer(key) do
    fn payload ->
      case payload[key] do
        value when is_integer(value) -> :ok
        _ -> {:error, %{payload: "#{key} must be an integer"}}
      end
    end
  end

  defp required_boolean(key) do
    fn payload ->
      case payload[key] do
        value when is_boolean(value) -> :ok
        _ -> {:error, %{payload: "#{key} must be a boolean"}}
      end
    end
  end

  defp optional_boolean(key) do
    fn payload ->
      case payload[key] do
        nil -> :ok
        value when is_boolean(value) -> :ok
        _ -> {:error, %{payload: "#{key} must be a boolean"}}
      end
    end
  end

  defp required_map(key) do
    fn payload ->
      case payload[key] do
        value when is_map(value) -> :ok
        _ -> {:error, %{payload: "#{key} must be a map"}}
      end
    end
  end

  defp required_list(key) do
    fn payload ->
      case payload[key] do
        value when is_list(value) -> :ok
        _ -> {:error, %{payload: "#{key} must be a list"}}
      end
    end
  end

  defp optional_map(key) do
    fn payload ->
      case payload[key] do
        nil -> :ok
        value when is_map(value) -> :ok
        _ -> {:error, %{payload: "#{key} must be a map"}}
      end
    end
  end

  defp optional_string(key) do
    fn payload ->
      case payload[key] do
        nil -> :ok
        value when is_binary(value) -> :ok
        _ -> {:error, %{payload: "#{key} must be a string"}}
      end
    end
  end

  defp optional_list(key) do
    fn payload ->
      case payload[key] do
        nil -> :ok
        value when is_list(value) -> :ok
        _ -> {:error, %{payload: "#{key} must be a list"}}
      end
    end
  end

  defp required_field(key) do
    fn payload ->
      if Map.has_key?(payload, key), do: :ok, else: {:error, %{payload: "#{key} is required"}}
    end
  end

  defp normalize_map(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_value(value)}
      {key, value} -> {key, normalize_value(value)}
    end)
  end

  defp normalize_map(_), do: %{}

  defp normalize_value(%{} = map), do: normalize_map(map)
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(value), do: value
end
