defmodule TodoClient.Repo do
  @moduledoc """
  SQLite repo backing the LocalOutbox offline stack: the local authoritative
  `local_todos` table, the `outbox_entries` replication queue, and Oban Lite's
  `oban_jobs`. One file per client instance (`TODO_DB_PATH`), so two instances
  keep independent local state. WAL mode + `pool_size: 1` — a single-writer demo.
  """
  use AshSqlite.Repo, otp_app: :todo_client

  @impl AshSqlite.Repo
  def installed_extensions, do: []
end
