defmodule TodoClient.Local.TodoList do
  @moduledoc """
  Generated from the published server manifest with `mix ash_remote.gen`,
  then adapted to the local SQLite authority and LocalOutbox replication.
  """
  use Ash.Resource,
    domain: TodoClient.Local,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshRemote.DataLayer, AshSqlite.DataLayer],
    notifiers: [TodoClient.Local.InboundNotifier, TodoClient.RealtimeBridge],
    # Generated actions are manifest-mirrored stubs, not hand-authored
    # primary reads — the "did you mean to put preparations/arguments on
    # your primary read?" warning this silences never applies to them.
    primary_read_warning?: false

  multi_data_layer do
    orchestrator {AshMultiDatalayer.Orchestrator.LocalOutbox,
                  outbox_resource: TodoClient.Sync.OutboxEntry, hydrate: :manual}

    layer :local, AshSqlite.DataLayer
    layer :remote, AshRemote.DataLayer

    read_order [:local]
    write_order [:local, :remote]
  end

  remote do
    source "TodoServer.TodoList"
    schema_version "1.0.0"
    realtime? true
  end

  sqlite do
    table "local_todo_lists"
    repo TodoClient.Repo
  end

  actions do
    create :create do
      primary? true
      accept [:id, :name, :public]
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end

    read :read do
      primary? true
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:name, :public]
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :inserted_at, :utc_datetime_usec, public?: true, writable?: false
    attribute :name, :string, public?: true, allow_nil?: false
    attribute :public, :boolean, public?: true
  end

  relationships do
    has_many :todos, TodoClient.Local.Todo,
      public?: true,
      source_attribute: :id,
      destination_attribute: :list_id
  end
end
