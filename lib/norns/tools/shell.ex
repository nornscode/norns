defmodule Norns.Tools.Shell do
  @moduledoc """
  Shell command execution tool with an allowlist for safety.

  Configure the allowlist via:
    config :norns, Norns.Tools.Shell, allowlist: ["echo", "ls", ...]
  """

  use Norns.Tools.Behaviour

  @default_allowlist ~w(echo date ls cat wc head tail grep find pwd whoami uname env sort uniq tr cut)
  @max_output_length 10_000
  @timeout_ms 30_000

  @impl true
  def name, do: "shell"

  @impl true
  def description, do: "Execute a shell command. Only allowlisted commands are permitted."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "description" => "The shell command to execute"}
      },
      "required" => ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command}) do
    cmd_name = command |> String.trim() |> String.split(~r/\s+/, parts: 2) |> List.first()

    if cmd_name in allowlist() do
      run_command(command)
    else
      {:error, "Command '#{cmd_name}' is not allowed. Allowed: #{Enum.join(allowlist(), ", ")}"}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: command"}

  defp run_command(command) do
    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], stderr_to_stdout: true)
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task) do
      {:ok, {output, exit_code}} ->
        truncated = String.slice(output, 0, @max_output_length)
        suffix = if String.length(output) > @max_output_length, do: "\n...(truncated)", else: ""
        {:ok, "Exit code: #{exit_code}\n\n#{truncated}#{suffix}"}

      nil ->
        {:error, "Command timed out after #{div(@timeout_ms, 1000)} seconds"}
    end
  end

  defp allowlist do
    Application.get_env(:norns, __MODULE__, [])
    |> Keyword.get(:allowlist, @default_allowlist)
  end
end
