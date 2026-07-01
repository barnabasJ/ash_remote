defmodule AshRemote.Backend.RpcRouter do
  @moduledoc "The reference backend's RPC endpoints — ash_remote's built-in router."
  use AshRemote.Server.Router, otp_app: :ash_remote
end
