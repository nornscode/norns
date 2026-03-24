defmodule NornsWeb.AgentChannelTest do
  use NornsWeb.ChannelCase, async: false

  alias NornsWeb.{AgentSocket, AgentChannel}

  setup do
    tenant = create_tenant()
    agent = create_agent(tenant)
    token = tenant.api_keys |> Map.values() |> List.first()

    {:ok, socket} = connect(AgentSocket, %{"token" => token})

    %{socket: socket, tenant: tenant, agent: agent}
  end

  describe "join" do
    test "joins agent channel successfully", %{socket: socket, agent: agent} do
      assert {:ok, _reply, _socket} = subscribe_and_join(socket, AgentChannel, "agent:#{agent.id}")
    end

    test "rejects join for non-existent agent", %{socket: socket} do
      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket, AgentChannel, "agent:999999")
    end
  end

  describe "PubSub forwarding" do
    test "forwards agent events to channel", %{socket: socket, agent: agent} do
      {:ok, _, _socket} = subscribe_and_join(socket, AgentChannel, "agent:#{agent.id}")

      # Simulate an agent process broadcasting via PubSub
      Phoenix.PubSub.broadcast(Norns.PubSub, "agent:#{agent.id}", {:llm_response, %{step: 1, content: "hello"}})

      assert_push "llm_response", %{step: 1, content: "hello"}
    end

    test "forwards completion events", %{socket: socket, agent: agent} do
      {:ok, _, _socket} = subscribe_and_join(socket, AgentChannel, "agent:#{agent.id}")

      Phoenix.PubSub.broadcast(Norns.PubSub, "agent:#{agent.id}", {:completed, %{output: "done"}})

      assert_push "completed", %{output: "done"}
    end
  end

  describe "send_message" do
    test "auto-starts agent and accepts message", %{socket: socket, agent: agent} do
      {:ok, _, socket} = subscribe_and_join(socket, AgentChannel, "agent:#{agent.id}")

      ref = push(socket, "send_message", %{"content" => "hello"})
      assert_reply ref, :ok, %{}
    end
  end

  describe "socket authentication" do
    test "rejects connection without token" do
      assert :error = connect(AgentSocket, %{})
    end

    test "rejects connection with invalid token" do
      assert :error = connect(AgentSocket, %{"token" => "bad-token"})
    end
  end
end
