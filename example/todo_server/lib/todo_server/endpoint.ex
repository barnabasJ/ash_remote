defmodule TodoServer.Endpoint do
  @moduledoc """
  A single Phoenix endpoint serving both transports on one port:

    * the realtime socket at `/ash_remote/socket`, and
    * the ash_remote RPC routes (+ token issuance) via `TodoServer.WebRouter`.
  """
  use Phoenix.Endpoint, otp_app: :todo_server

  socket("/ash_remote/socket", TodoServer.RemoteSocket, websocket: true, longpoll: false)

  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(TodoServer.WebRouter)
end
