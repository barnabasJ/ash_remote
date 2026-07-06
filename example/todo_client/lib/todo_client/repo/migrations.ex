defmodule TodoClient.Repo.Migrations do
  @moduledoc """
  Hand-written migrations for the LocalOutbox SQLite file, run at app boot via
  `Ecto.Migrator` (idempotent — safe to re-run). Three schemas share the one DB:

    * `local_todos`     — the local authoritative copy (`TodoClient.Local.Todo`)
    * `outbox_entries`  — the replication queue (`TodoClient.Sync.OutboxEntry`,
                          matching the extension-injected attribute shape)
    * `oban_jobs`       — Oban Lite's queue table (`Oban.Migrations.up/0`)
  """

  defmodule Tables do
    @moduledoc false
    use Ecto.Migration

    def up do
      create_if_not_exists table("local_todos", primary_key: false) do
        add(:id, :uuid, primary_key: true)
        add(:title, :text, null: false)
        add(:completed, :boolean, default: false)
        add(:public, :boolean, default: false)
        add(:priority, :text)
        add(:due_date, :date)
        add(:inserted_at, :utc_datetime_usec)
        add(:updated_at, :utc_datetime_usec)
        # Client-authored conflict counter (TodoClient.BumpVersion) — the field
        # LocalOutbox stale-checks. Fresh DBs each run, so it lives in the base
        # migration rather than a separate ALTER.
        add(:version, :integer, default: 1)
      end

      create_if_not_exists table("outbox_entries", primary_key: false) do
        # INTEGER PRIMARY KEY → SQLite rowid, monotonically autoincrementing.
        add(:seq, :integer, primary_key: true)
        add(:write_ref, :uuid, null: false)
        add(:resource, :text, null: false)
        add(:tenant, :text)
        add(:record_pk, :map, null: false)
        add(:op, :text, null: false)
        add(:payload, :map)
        add(:base_image, :map)
        add(:remote_snapshot, :map)
        add(:target, :text, null: false)
        add(:state, :text, null: false, default: "pending")
        add(:error_class, :text)
        add(:last_error, :map)
        add(:parked_at, :utc_datetime_usec)
        add(:inserted_at, :utc_datetime_usec, null: false)
        add(:updated_at, :utc_datetime_usec, null: false)
      end
    end

    def down do
      drop(table("local_todos"))
      drop(table("outbox_entries"))
    end
  end

  defmodule ObanJobs do
    @moduledoc false
    use Ecto.Migration

    # Dispatches to Oban.Migrations.SQLite for the ecto_sqlite3 adapter, creating
    # the Lite engine's `oban_jobs` table. Named `ObanJobs` (not `Oban`) so the
    # auto-alias of a nested `Oban` module doesn't shadow `Oban.Migrations`.
    def up, do: Oban.Migrations.up()
    def down, do: Oban.Migrations.down()
  end

  @doc """
  Bring every schema up against the already-started `TodoClient.Repo`. Idempotent
  (`Ecto.Migrator.up` no-ops an applied version). The SQLite file is created when
  the supervised repo first connects, so no explicit `storage_up` is needed.
  """
  def migrate! do
    repo = TodoClient.Repo
    Ecto.Migrator.up(repo, 1, Tables, log: false)
    Ecto.Migrator.up(repo, 2, ObanJobs, log: false)
    :ok
  end

  @doc """
  A supervised child that runs `migrate!/0` synchronously in its `start_link`,
  then returns `:ignore`. Placed after `TodoClient.Repo` and before `Oban` in the
  tree, `:one_for_one` guarantees the tables exist before Oban Lite boots.
  """
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker, restart: :transient}
  end

  def start_link do
    migrate!()
    :ignore
  end
end
