defmodule TodoClient.Remote.Todo do
  # Hand-edited after `mix ash_remote.gen` — re-apply after any regen (see the
  # client README): swapped `data_layer:` for `AshMultiDatalayer.DataLayer`
  # (+ the `multi_data_layer` block below) to front the remote data layer with
  # an ETS cache; since `AshRemote.DataLayer` is no longer the top-level
  # `data_layer:`, its `remote do ... end` section needs `extensions:
  # [AshRemote.DataLayer]` explicitly (a plain regen gets it for free); and
  # added TodoClient.RemoteChangeNotifier first so peer notifications invalidate
  # the cache before the UI refetches, while this client's own websocket echo
  # does not invalidate the cache a second time.
  use Ash.Resource,
    domain: TodoClient.Remote.Domain,
    data_layer: AshMultiDatalayer.DataLayer,
    extensions: [AshRemote.DataLayer],
    notifiers: [TodoClient.RemoteChangeNotifier, TodoClient.RealtimeBridge],
    # Mirrored from the manifest, not hand-authored: the primary read carries
    # the server's validations, which Ash's primary-read verifier flags as a
    # likely mistake. `mix ash_remote.gen` emits this on every resource now.
    primary_read_warning?: false

  multi_data_layer do
    layer :cache, Ash.DataLayer.Ets
    layer :remote, AshRemote.DataLayer

    read_order [:cache, :remote]
    write_order [:remote, :cache]
  end

  remote do
    source "TodoServer.Todo"
    schema_version "1.0.0"
    realtime? true
  end

  actions do
    create :create do
      primary? true
      # :version accepted so it survives AshRemote's accepted-keys wire filter (see
      # TodoClient.Local.Todo) and replicates.
      accept [:title, :completed, :public, :priority, :due_date, :list_id, :version]
      change TodoClient.BumpVersion
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      argument :expected_version, :integer
    end

    read :read do
      primary? true
      prepare AshRemote.PrefetchCalculations
    end

    update :update do
      primary? true
      require_atomic? false
      argument :expected_version, :integer
      accept [:title, :completed, :public, :priority, :due_date, :list_id, :version]
      change TodoClient.BumpVersion
    end
  end

  validations do
    validate string_length(:title, min: 3)
  end

  attributes do
    attribute :completed, :boolean, public?: true
    attribute :due_date, :date, public?: true
    uuid_primary_key :id
    attribute :inserted_at, :utc_datetime_usec, public?: true
    attribute :priority, TodoClient.Remote.Priority, public?: true
    attribute :public, :boolean, public?: true
    attribute :title, :string, public?: true, allow_nil?: false
    # Client-authored conflict counter (see TodoClient.BumpVersion). The server
    # exposes it publicly, so this cache mirror carries it too — both to decode
    # server rows cleanly and to advance it on cache-side (`/`) edits, keeping the
    # version monotonic no matter which strategy wrote the row.
    attribute :version, :integer, public?: true, default: 1
  end

  relationships do
    belongs_to :list, TodoClient.Remote.TodoList,
      public?: true,
      attribute_writable?: true,
      source_attribute: :list_id,
      destination_attribute: :id
  end

  calculations do
    calculate :overdue?,
              :boolean,
              expr(not is_nil(due_date) and due_date < today() and not completed) do
      public? true
    end
  end
end
