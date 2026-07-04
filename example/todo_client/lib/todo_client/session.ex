defmodule TodoClient.Session do
  @moduledoc """
  Authenticates this client instance against todo_server at boot (email/password
  → JWT) and holds the token. Run two instances as different users
  (`TODO_EMAIL=grace@example.com WEB_PORT=4002 mix phx.server`) to see per-user
  filtering; both still see PUBLIC todos live.

  The token is forwarded on every RPC call (`context/0`) and on the realtime
  socket connect (`connect_params/0`), so the whole instance acts as one user.
  """
  use Agent

  require Logger

  def start_link(_opts) do
    Agent.start_link(&sign_in/0, name: __MODULE__)
  end

  def token, do: Agent.get(__MODULE__, & &1[:token])
  def user, do: Agent.get(__MODULE__, & &1[:user])

  @doc "connect_params for AshRemote.Realtime — the JWT the socket authenticates with."
  def connect_params, do: %{"token" => token() || ""}

  @doc """
  The actor to pass on RPC calls: a `TodoClient.CurrentUser` carrying the JWT in
  metadata, which `AshRemote.DataLayer` auto-forwards as a Bearer token (and which
  propagates to relationship loads, unlike a bare context).
  """
  def actor, do: Agent.get(__MODULE__, & &1[:actor])

  defp sign_in do
    base = Application.fetch_env!(:ash_remote, :base_url)
    email = System.get_env("TODO_EMAIL", "ada@example.com")
    password = System.get_env("TODO_PASSWORD", "password123")

    case Req.post(base <> "/auth/sign-in", json: %{email: email, password: password}) do
      {:ok, %{status: 200, body: %{"token" => token, "user" => user}}} ->
        Logger.info("todo_client signed in as #{user["email"]}")
        %{token: token, user: user, actor: TodoClient.CurrentUser.new(user, token)}

      other ->
        Logger.error("todo_client sign-in failed: #{inspect(other)}")
        %{token: nil, user: nil, actor: nil}
    end
  end
end
