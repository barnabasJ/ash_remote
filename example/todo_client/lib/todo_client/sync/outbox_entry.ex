defmodule TodoClient.Sync.OutboxEntry do
  @moduledoc """
  The LocalOutbox replication queue. The `AshMultiDatalayer.Sync.OutboxEntry`
  extension injects the whole contract — attributes (`seq`, `write_ref`,
  `resource`, `record_pk`, `op`, `payload`, `base_image`, `remote_snapshot`,
  `state`, `error_class`, …), the `enqueue`/`flush`/`park`/`retry`/`discard`
  actions, and the ash_oban `:flush` trigger — so this module is just its SQLite
  table + queue config. AshOban is added automatically by the extension.
  """
  use Ash.Resource,
    domain: TodoClient.Sync,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshMultiDatalayer.Sync.OutboxEntry],
    # A notifier (fires AFTER the flush commits — not a lifecycle hook) so the
    # editing client's OfflineLive learns its own entry flipped pending→synced and
    # re-renders its sync badge promptly, instead of lagging until the next poll.
    # It's excluded from its own server echo, so this local signal is what keeps
    # the editor's badge honest.
    notifiers: [TodoClient.Sync.OutboxNotifier]

  sqlite do
    table("outbox_entries")
    repo(TodoClient.Repo)
  end

  outbox_entry do
    queue(:todo_sync)
    max_attempts(10)
  end
end
