defmodule Norns.Runtime.Events.SubagentLaunched do
  @moduledoc false

  alias Norns.Runtime.Events

  def new(attrs), do: Events.build("subagent_launched", attrs)
end
