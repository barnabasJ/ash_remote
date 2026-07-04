defmodule AshRemote.Backend.RemoteSocket do
  @moduledoc """
  Test host socket. Allows subscriptions normally, but denies whenever the join
  params carry `"deny" => true` — exercising the `authorize_subscription/4`
  hook's allow and deny paths.
  """
  use AshRemote.Server.Socket, otp_app: :ash_remote

  @impl true
  def authorize_subscription(_resource, _tenant, %{"deny" => true}, _socket), do: :error
  def authorize_subscription(_resource, _tenant, _params, _socket), do: :ok
end
