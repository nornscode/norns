defmodule Norns.Workers.HttpSignature do
  @moduledoc """
  Signs the tasks Norns POSTs to an HTTP worker, so the worker can check the
  request came from Norns and is recent.

  Header: `X-Norns-Signature: t=<unix seconds>,v1=<hex hmac-sha256>`, where
  the MAC is over `"<t>.<raw body>"` under the worker's secret. This is the
  Stripe scheme — `Norns.Hooks.Signature` already verifies it on the way in,
  so a worker SDK can reuse one implementation for both directions.

  `verify/3` is here for tests and for the Elixir SDK; other SDKs implement
  the same check against the raw bytes they received.
  """

  @header "x-norns-signature"
  @tolerance_seconds 300

  def header_name, do: @header

  @doc "Build the signature header value for `body` at `timestamp`."
  def sign(secret, body, timestamp \\ System.os_time(:second)) when is_binary(body) do
    "t=#{timestamp},v1=#{hmac_hex(secret, "#{timestamp}.#{body}")}"
  end

  @doc """
  Verify a header value against `raw_body`. Returns `:ok` or `{:error, code}`
  with `"missing_signature"`, `"invalid_signature"` or `"stale_timestamp"`.
  """
  def verify(secret, raw_body, header) when is_binary(header) do
    with %{"t" => timestamp, "v1" => signature} <- parse(header),
         :ok <- check_timestamp(timestamp) do
      expected = hmac_hex(secret, "#{timestamp}.#{raw_body}")

      if Plug.Crypto.secure_compare(signature, expected),
        do: :ok,
        else: {:error, "invalid_signature"}
    else
      {:error, _} = error -> error
      _ -> {:error, "missing_signature"}
    end
  end

  def verify(_secret, _raw_body, _header), do: {:error, "missing_signature"}

  defp hmac_hex(secret, data) do
    :hmac |> :crypto.mac(:sha256, secret, data) |> Base.encode16(case: :lower)
  end

  defp parse(header) do
    header
    |> String.split(",")
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), value)
        _ -> acc
      end
    end)
  end

  defp check_timestamp(timestamp) do
    with {seconds, ""} <- Integer.parse(timestamp),
         true <- abs(System.os_time(:second) - seconds) <= @tolerance_seconds do
      :ok
    else
      _ -> {:error, "stale_timestamp"}
    end
  end
end
