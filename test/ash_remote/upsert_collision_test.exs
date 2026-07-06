defmodule AshRemote.UpsertCollisionTest do
  @moduledoc """
  R-7 (fix-plan Phase B0-4 / B2-2): `AshRemote.DataLayer.upsert/3` decides
  create-vs-update from a plain, non-atomic read (`remote_pk_row/2`) — two
  concurrent upserts for the same PK can both observe `{:ok, nil}` and both
  attempt `create`; the second one collides against the server's unique
  primary key. Deterministically reproduced (no sleeps) via
  `AshRemote.Test.RaceTransport`, which parks the racer's read AFTER
  capturing its (stale) `nil` response, mirroring
  `ash_multi_datalayer`'s `BlockingLayer` pattern.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  require Ash.Query

  alias AshRemote.Backend.TestBackend
  alias AshRemote.Client.RaceItem
  alias AshRemote.Test.RaceTransport
  alias AshRemote.Transport.Config

  setup do
    RaceTransport.ensure_table!()
    TestBackend.reset!()

    Application.put_env(:ash_remote, :remote_config, %{
      RaceItem => %{
        source: "AshRemote.Backend.RaceItem",
        transport: Config.new(base_url: TestBackend.base_url(), module: RaceTransport)
      }
    })

    on_exit(fn -> Application.delete_env(:ash_remote, :remote_config) end)
    :ok
  end

  test "two concurrent upserts to the same PK never duplicate — the loser resolves to update" do
    id = Ash.UUID.generate()

    race_changeset = Ash.Changeset.for_create(RaceItem, :create, %{id: id, title: "race"})

    RaceTransport.arm()

    task = Task.async(fn -> AshRemote.DataLayer.upsert(RaceItem, race_changeset, [:id]) end)

    assert_receive {:race_transport_parked, reader_pid}, 1000

    # The "winner": creates the row for real while the racer's read is
    # parked holding its stale (pre-creation) nil.
    assert {:ok, _} = Ash.create(RaceItem, %{id: id, title: "winner"})

    RaceTransport.release(reader_pid)
    result = Task.await(task)

    # The collision must resolve — never surface as an uncaught duplicate
    # error, and never silently create a second row.
    assert {:ok, %RaceItem{id: ^id}} = result
    assert [%RaceItem{id: ^id}] = RaceItem |> Ash.Query.filter(id == ^id) |> Ash.read!()
  end
end
