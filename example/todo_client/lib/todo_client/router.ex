defmodule TodoClient.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Oban.Web.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {TodoClient.Layout, :root})
    plug(:protect_from_forgery)
  end

  scope "/" do
    pipe_through(:browser)
    live("/", TodoClient.Live)
    live("/offline", TodoClient.OfflineLive)
    # The Oban dashboard — watch the LocalOutbox flush jobs (queue :todo_sync)
    # enqueue and drain in real time.
    oban_dashboard("/oban")
  end
end
