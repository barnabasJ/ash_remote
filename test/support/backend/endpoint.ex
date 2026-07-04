defmodule AshRemote.Backend.Endpoint do
  @moduledoc """
  Minimal Phoenix endpoint for the realtime tests: mounts the realtime socket
  only (no router). Runs on port 4748, separate from the Bandit HTTP reference
  backend on 4747.
  """
  use Phoenix.Endpoint, otp_app: :ash_remote

  socket("/ash_remote/socket", AshRemote.Backend.RemoteSocket,
    websocket: true,
    longpoll: false
  )
end
