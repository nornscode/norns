defmodule Norns.Tools.ShellTest do
  use ExUnit.Case, async: true

  alias Norns.Tools.Shell

  describe "behaviour" do
    test "implements all callbacks" do
      assert Shell.name() == "shell"
      assert is_binary(Shell.description())
      assert is_map(Shell.input_schema())
    end
  end

  describe "execute/1" do
    test "runs an allowed command" do
      assert {:ok, result} = Shell.execute(%{"command" => "echo hello world"})
      assert result =~ "Exit code: 0"
      assert result =~ "hello world"
    end

    test "blocks disallowed commands" do
      assert {:error, msg} = Shell.execute(%{"command" => "rm -rf /"})
      assert msg =~ "not allowed"
    end

    test "returns exit code for failing commands" do
      assert {:ok, result} = Shell.execute(%{"command" => "ls /nonexistent_path_xyz"})
      # ls returns non-zero for missing path
      refute result =~ "Exit code: 0"
    end

    test "returns error for missing command" do
      assert {:error, _} = Shell.execute(%{})
    end

    test "handles commands with pipes" do
      assert {:ok, result} = Shell.execute(%{"command" => "echo hello | wc -c"})
      assert result =~ "Exit code: 0"
    end
  end
end
