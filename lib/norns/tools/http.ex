defmodule Norns.Tools.Http do
  @moduledoc "HTTP request tool. Makes GET/POST requests via Req."

  use Norns.Tools.Behaviour

  @max_body_length 10_000

  @impl true
  def name, do: "http_request"

  @impl true
  def description, do: "Make an HTTP request. Supports GET and POST methods."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "description" => "The URL to request"},
        "method" => %{"type" => "string", "enum" => ["GET", "POST"], "description" => "HTTP method (default: GET)"},
        "body" => %{"type" => "string", "description" => "Request body for POST requests"},
        "headers" => %{"type" => "object", "description" => "Optional HTTP headers"}
      },
      "required" => ["url"]
    }
  end

  @impl true
  def execute(%{"url" => url} = input) do
    method = String.upcase(input["method"] || "GET")
    headers = parse_headers(input["headers"])
    body = input["body"]

    result =
      case method do
        "GET" ->
          Req.get(url, headers: headers, receive_timeout: 30_000, retry: false)

        "POST" ->
          opts = [headers: headers, receive_timeout: 30_000, retry: false]
          opts = if body, do: Keyword.put(opts, :body, body), else: opts
          Req.post(url, opts)

        other ->
          {:error, "Unsupported method: #{other}"}
      end

    case result do
      {:ok, %Req.Response{status: status, body: body}} ->
        body_str = if is_binary(body), do: body, else: Jason.encode!(body)
        truncated = String.slice(body_str, 0, @max_body_length)
        suffix = if String.length(body_str) > @max_body_length, do: "\n...(truncated)", else: ""
        {:ok, "HTTP #{status}\n\n#{truncated}#{suffix}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: url"}

  defp parse_headers(nil), do: []
  defp parse_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end
  defp parse_headers(_), do: []
end
