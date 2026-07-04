defmodule AshRemote.Backend.RemoteSocket do
  @moduledoc """
  Test host socket. Allows subscriptions normally, but denies whenever the join
  params carry `"deny" => true` — exercising the `authorize_subscription/4`
  hook's allow and deny paths.
  """
  use AshRemote.Server.Socket, otp_app: :ash_remote

  # Establish the actor from a connect param, standing in for real token auth,
  # so the channel's per-record authorization has an actor to check.
  @impl true
  def connect(params, socket, connect_info) do
    {:ok, socket} = super(params, socket, connect_info)

    case params do
      %{"actor_id" => actor_id} ->
        {:ok, Phoenix.Socket.assign(socket, :ash_remote_actor, %{id: actor_id})}

      _ ->
        {:ok, socket}
    end
  end

  @impl true
  def authorize_subscription(_resource, _tenant, %{"deny" => true}, _socket), do: :error
  def authorize_subscription(_resource, _tenant, _params, _socket), do: :ok
end
