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
    live "/gards", GardsLive
    live "/telemetry", TelemetryLive
  end

  pipeline :api_public do
    plug :accepts, ["json"]
  end

  scope "/api/v1", NornsWeb do
    pipe_through :api_public

    post "/telemetry/first-run", TelemetryController, :first_run

    # Webhook ingress — the token in the path is the credential; provider
    # signature verification happens in the controller against the raw body.
    post "/hooks/:token", HookIngestController, :create
  end

  scope "/api/v1", NornsWeb do
    pipe_through :api

    resources "/agents", AgentController, only: [:create, :index, :show, :update, :delete] do
      post "/messages", AgentController, :send_message
      get "/status", AgentController, :status
      get "/runs", AgentController, :runs
      get "/conversations", ConversationController, :index
      get "/conversations/:key", ConversationController, :show
      delete "/conversations/:key", ConversationController, :delete
    end

    get "/tools", ToolController, :index
    get "/workers", WorkerController, :index

    resources "/triggers", TriggerController, only: [:create, :index, :show, :update, :delete] do
      post "/fire", TriggerController, :fire
    end

    resources "/gards", GardController, only: [:create, :index, :show, :update, :delete] do
      get "/ports", GardController, :ports
    end

    # Hook management. No collision with public ingest: ingest is POST
    # /hooks/:token, and nothing here answers POST on /hooks/:id.
    resources "/hooks", HookController, only: [:create, :index, :show, :update, :delete]

    get "/sessions", SessionController, :index
    get "/sessions/:id", SessionController, :show
    delete "/sessions/:id", SessionController, :delete
    post "/sessions/:id/restore", SessionController, :restore
    get "/runs", RunController, :index
    get "/runs/:id", RunController, :show
    get "/runs/:id/events", RunController, :events
    get "/runs/:id/summary", RunController, :summary
    post "/runs/:id/retry", RunController, :retry
    post "/runs/:id/reply", RunController, :reply
    post "/runs/:id/fork", RunController, :fork
  end
end
