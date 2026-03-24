defmodule Norns.Types.JsonList do
  @moduledoc "Ecto type for JSON arrays stored in a jsonb column."

  @behaviour Ecto.Type

  def type, do: :map

  def cast(value) when is_list(value), do: {:ok, value}
  def cast(_value), do: :error

  def load(value) when is_list(value), do: {:ok, value}
  def load(_value), do: :error

  def dump(value) when is_list(value), do: {:ok, value}
  def dump(_value), do: :error

  def embed_as(_format), do: :self

  def equal?(left, right), do: left == right
end
