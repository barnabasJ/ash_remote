defmodule TodoClient.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # In test the e2e harness starts the backend + session itself (after the
    # in-process server is up), so skip the auto-start tree.
    children =
      if Application.get_env(:todo_client, :start_children, true) do
        [
          {Phoenix.PubSub, name: TodoClient.PubSub},
          # Authenticate this instance before the realtime socket connects.
          TodoClient.Session,
          # One websocket to todo_server, auto-joining a topic per `realtime?`
          # resource, carrying this instance's JWT as the connect token.
          {AshRemote.Realtime,
           otp_app: :todo_client, connect_params: {TodoClient.Session, :connect_params, []}},
          TodoClient.Endpoint
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: TodoClient.Supervisor)
  end
end
