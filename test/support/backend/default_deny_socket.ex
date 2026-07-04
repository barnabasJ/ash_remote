defmodule AshRemote.Backend.DefaultDenySocket do
  @moduledoc """
  A socket that does NOT override `authorize_subscription/4`, used to prove the
  macro's default is deny.
  """
  use AshRemote.Server.Socket, otp_app: :ash_remote
end
