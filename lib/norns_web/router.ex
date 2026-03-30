defmodule NornsWeb.Router do
  use NornsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NornsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug NornsWeb.Plugs.SessionAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug NornsWeb.Plugs.Auth
  end

  scope "/", NornsWeb do
    pipe_through :browser

    live "/", AgentsLive
    live "/setup", SetupLive
    live "/agents/:id", AgentLive
    live "/runs/:id", RunLive
    live "/tools", ToolsLive
  end

  scope "/api/v1", NornsWeb do
    pipe_through :api

    resources "/agents", AgentController, only: [:create, :index, :show, :update] do
      post "/messages", AgentController, :send_message
      get "/status", AgentController, :status
      get "/runs", AgentController, :runs
      get "/conversations", ConversationController, :index
      get "/conversations/:key", ConversationController, :show
      delete "/conversations/:key", ConversationController, :delete
    end

    get "/runs/:id", RunController, :show
    get "/runs/:id/events", RunController, :events
  end
end
