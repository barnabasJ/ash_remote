defmodule TodoServer.Auth do
  @moduledoc """
  Shared auth helpers: verify an ash_authentication JWT and resolve the user it
  identifies. Used by both the RPC auth plug (`TodoServer.AuthPlug`) and the
  realtime socket (`TodoServer.RemoteSocket`) so RPC and subscriptions
  authenticate identically.
  """

  @doc "Resolve a JWT to `{:ok, user}` or `:error`."
  def token_to_user(token) when is_binary(token) do
    with {:ok, claims, resource} <- AshAuthentication.Jwt.verify(token, :todo_server),
         {:ok, user} <- AshAuthentication.subject_to_user(claims["sub"], resource) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  def token_to_user(_), do: :error
end
