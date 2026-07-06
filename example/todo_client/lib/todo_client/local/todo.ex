defmodule TodoClient.Local.Todo do
  @moduledoc """
  Offline-first todo. The LocalOutbox orchestrator makes a local SQLite layer the
  authority: every read is served from SQLite (0 RPC), every write commits to
  SQLite and co-commits an outbox entry that an Oban worker later flushes to the
  server (`AshRemote.DataLayer`). `conflict_detection: {:stale_check, :updated_at}`
  parks a flush whose server row moved since this client last saw it — surfaced in
  `TodoClient.OfflineLive` for three-way resolution.

  `updated_at` is a **plain attribute** (not an `update_timestamp`): it carries the
  server-assigned value through hydration and into each write's `base_image`, so
  the stale-check compares the client's last-known server timestamp against the
  server's current one. `hydrate: :manual` — the app hydrates after sign-in
  (`TodoClient.Application`) so it can carry the actor's token.
  """
  use Ash.Resource,
    domain: TodoClient.Local,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshRemote.Resource, AshSqlite.DataLayer],
    # Inbound realtime for a local-first resource. InboundNotifier runs FIRST — it
    # wraps the strategy-agnostic AshMultiDatalayer.Notifiers.ExternalChange
    # (which routes the replayed server change to LocalOutbox.handle_external_change
    # → refresh into the local SQLite authority, dirty-rule aware) with the demo's
    # offline simulation: while sync is paused it drops the change, so a paused
    # ("offline") client genuinely falls behind and catches up via refresh(:all) on
    # resume. RealtimeBridge then tells OfflineLive to reload. When online this is
    # the ordinary inbound path unchanged.
    notifiers: [TodoClient.Local.InboundNotifier, TodoClient.RealtimeBridge]

  multi_data_layer do
    orchestrator(
      {AshMultiDatalayer.Orchestrator.LocalOutbox,
       outbox_resource: TodoClient.Sync.OutboxEntry,
       conflict_detection: {:stale_check, :updated_at},
       hydrate: :manual}
    )

    layer(:local, AshSqlite.DataLayer)
    layer(:remote, AshRemote.DataLayer)

    read_order([:local])
    write_order([:local, :remote])
  end

  sqlite do
    table("local_todos")
    repo(TodoClient.Repo)
  end

  remote do
    source("TodoServer.Todo")
    schema_version("1.0.0")
    # Subscribe to server-side changes so a peer's write pushes in over the
    # realtime socket (see the notifiers above) instead of waiting for a poll.
    realtime?(true)
  end

  attributes do
    # Writable so the locally-generated id replicates to the server as the same
    # row id (offline-first). Included in the `:create` accept below so the flush
    # carries it on the create push.
    attribute :id, :uuid do
      primary_key?(true)
      allow_nil?(false)
      writable?(true)
      default(&Ash.UUID.generate/0)
      public?(true)
    end

    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:completed, :boolean, public?: true, default: false)
    attribute(:public, :boolean, public?: true, default: false)
    attribute(:priority, TodoClient.Remote.Priority, public?: true, default: :medium)
    attribute(:due_date, :date, public?: true)
    attribute(:inserted_at, :utc_datetime_usec, public?: true)
    # The stale-check field — a plain attribute holding the server's value, never
    # auto-bumped locally (see the moduledoc).
    attribute(:updated_at, :utc_datetime_usec, public?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:id, :title, :completed, :public, :priority, :due_date])
    end

    update :update do
      primary?(true)
      require_atomic?(false)
      accept([:title, :completed, :public, :priority, :due_date])
    end
  end
end
