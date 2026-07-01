defmodule TodoServer.RpcRouter do
  @moduledoc "RPC endpoints for the todo backend — entirely from ash_remote."
  use AshRemote.Server.Router, otp_app: :todo_server
end
