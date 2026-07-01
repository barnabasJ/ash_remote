defmodule TodoClient.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :todo_client

  socket "/live", Phoenix.LiveView.Socket

  # Serve the LiveView JS straight from the deps (no build step).
  plug Plug.Static, at: "/js/phoenix", from: :phoenix, only: ["phoenix.js"]
  plug Plug.Static, at: "/js/live_view", from: :phoenix_live_view, only: ["phoenix_live_view.js"]

  plug Plug.Session,
    store: :cookie,
    key: "_todo_client",
    signing_salt: "todocli0",
    same_site: "Lax"

  plug TodoClient.Router
end
