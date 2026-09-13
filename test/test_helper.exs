ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Norns.Repo, :manual)

# Define a simple test tool for use in process tests
test_tool = %Norns.TestWorker.Tool{
  name: "web_search",
  description: "Test web search",
  input_schema: %{},
  handler: fn %{"query" => query} ->
    {:ok, "Search results for '#{query}': stub result"}
  end
}

# Start the test worker — serves the llm and tools tasks core dispatches
{:ok, _pid} = Norns.TestWorker.start_link(tools: [test_tool])
