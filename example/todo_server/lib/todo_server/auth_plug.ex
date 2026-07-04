defmodule TodoServer.AuthPlug do
  @moduledoc """
  Resolves a Bearer JWT into an actor and stashes it on the conn via
  `Ash.PlugHelpers`. `AshRemote.Server.Router` reads it and runs every RPC action
  as that user. No token → no actor (the resource policies then deny).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- TodoServer.Auth.token_to_user(token) do
      Ash.PlugHelpers.set_actor(conn, user)
    else
      _ -> conn
    end
  end
end
