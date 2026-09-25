defmodule AshRemote.ServerUpsertsTest do
  @moduledoc """
  Regression for the `server_upserts?` resource option (`AshRemote.Resource.Section`):
  `AshRemote.DataLayer.upsert/3`'s default strategy pre-checks remote existence via
  a real read (`remote_identity_row/3`), which needs a primary read action to
  dispatch — a resource whose only read is non-primary/argument-gated (no
  unfiltered list; mob_worker's real `Evv.Event` is exactly this shape) has none,
  and upsert/3 crashed with "no primary action of type :read". `server_upserts?`
  lets a resource whose remote create is already an idempotent upsert skip that
  check entirely.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Backend.TestBackend
  alias AshRemote.Client.UpsertOnly

  setup do
    TestBackend.reset!()
    Application.put_env(:ash_remote, :base_url, TestBackend.base_url())
    on_exit(fn -> Application.delete_env(:ash_remote, :base_url) end)
    :ok
  end

  test "AshRemote.Resource.Info exposes the flag, defaulting to false" do
    assert AshRemote.Resource.Info.remote_server_upserts?(UpsertOnly) == true
    assert AshRemote.Resource.Info.remote_server_upserts?(AshRemote.Client.Todo) == false
  end

  test "upsert/3 dispatches straight to create — no read, even though there's no primary read action" do
    token = Ash.UUID.generate()

    changeset =
      UpsertOnly
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attributes(%{token: token, title: "first"})

    assert {:ok, %UpsertOnly{token: ^token, title: "first"}} =
             AshRemote.DataLayer.upsert(UpsertOnly, changeset, [:token])
  end

  test "a re-flushed upsert for the same identity is idempotent (server-side upsert, not a client retry)" do
    token = Ash.UUID.generate()

    changeset = fn title ->
      UpsertOnly
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attributes(%{token: token, title: title})
    end

    assert {:ok, first} = AshRemote.DataLayer.upsert(UpsertOnly, changeset.("first"), [:token])
    assert {:ok, second} = AshRemote.DataLayer.upsert(UpsertOnly, changeset.("first"), [:token])

    assert first.id == second.id

    assert {:ok, [row]} =
             UpsertOnly
             |> Ash.Query.for_read(:by_token, %{token: token})
             |> Ash.read()

    assert row.id == first.id
  end
end
