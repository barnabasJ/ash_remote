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
          # LocalOutbox offline stack, started first: the SQLite authority, its
          # migrations (blocking — creates local_todos/outbox_entries/oban_jobs),
          # then Oban Lite draining the `:todo_sync` queue.
          TodoClient.Repo,
          TodoClient.Repo.Migrations,
          {Oban, Application.fetch_env!(:todo_client, Oban)},
          {Phoenix.PubSub, name: TodoClient.PubSub},
          AshMultiDatalayer.Supervisor,
          # Authenticate this instance before the realtime socket connects.
          TodoClient.Session,
          # Pull the server's todos into the local SQLite layer once signed in
          # (LocalOutbox `hydrate: :manual`). Runs in a Task so a cold/offline
          # server never blocks boot; carries the actor's JWT via remote_context.
          hydrate_spec(),
          # One websocket to todo_server, auto-joining a topic per `realtime?`
          # resource, carrying this instance's JWT as the connect token.
          # echo: :deliver — this client runs TWO stacks over the same server
          # resource (Remote.* ProvenCoverage cache + Local.* LocalOutbox).
          # A write through one stack invalidates only that stack's caches
          # locally; the broadcast echo is the only channel that reaches the
          # sibling stack, so suppressing it would leave e.g. the online
          # page's cache stale after this client's own offline-page write.
          {AshRemote.Realtime,
           otp_app: :todo_client,
           connect_params: {TodoClient.Session, :connect_params, []},
           echo: :deliver},
          # Closes the notification-gap AshRemote.Realtime documents. Started
          # AFTER AshRemote.Realtime: the Lifecycle registry it registers with
          # is created by AshRemote.Realtime's own supervisor init, so it must
          # already be running first (see AshRemote.MultiDatalayer.LifecycleGuard's
          # moduledoc for why this is safe).
          {AshRemote.MultiDatalayer.LifecycleGuard, realtime_names: [AshRemote.Realtime]},
          TodoClient.CacheStats,
          TodoClient.Endpoint
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: TodoClient.Supervisor)
  end

  # A transient Task child (started after Session, so the JWT is available) that
  # hydrates the local layer from the server, tolerating any error — an offline
  # or slow server must not crash the boot tree.
  defp hydrate_spec do
    Supervisor.child_spec(
      {Task,
       fn ->
         try do
           TodoClient.Local.Todo
           |> AshMultiDatalayer.Orchestrator.LocalOutbox.hydrate()
         rescue
           _ -> :ok
         catch
           _, _ -> :ok
         end
       end},
      id: :todo_client_hydrate,
      restart: :transient
    )
  end
end
