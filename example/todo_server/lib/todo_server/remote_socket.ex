defmodule TodoServer.RemoteSocket do
  @moduledoc """
  The realtime socket. Authenticates the connection from a `token` connect param
  (the same JWT used for RPC) and assigns the resolved user as the actor, so the
  channel's per-record authorization delivers only todos the user may read.
  """
  use AshRemote.Server.Socket, otp_app: :todo_server

  @impl true
  def connect(params, socket, connect_info) do
    {:ok, socket} = super(params, socket, connect_info)

    case TodoServer.Auth.token_to_user(params["token"]) do
      {:ok, user} -> {:ok, Phoenix.Socket.assign(socket, :ash_remote_actor, user)}
      _ -> {:ok, socket}
    end
  end

  # Only authenticated connections may join; the per-record gate does the rest.
  @impl true
  def authorize_subscription(_resource, _tenant, _params, socket) do
    if socket.assigns[:ash_remote_actor], do: :ok, else: :error
  end
end
