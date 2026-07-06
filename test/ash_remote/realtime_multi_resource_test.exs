defmodule AshRemote.RealtimeMultiResourceTest do
  @moduledoc """
  Regression: when several client resources map to the SAME server source (the
  real shape of an app mixing strategies over one backend resource — e.g. a
  cache mirror and a local-first mirror), a replicated server change must reach
  EVERY one of them. Before the fix, `AshRemote.Realtime` collapsed the shared
  source into a single dispatch target (`Map.new` keyed by source), so only the
  last-registered resource's notifiers fired and every other mirror silently
  went stale — the cross-client-invalidation regression in the demo.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Backend.TestBackend
  alias AshRemote.RealtimeClient.SecondTodo
  alias AshRemote.RealtimeClient.Todo, as: ClientTodo

  @socket_base "http://127.0.0.1:4748"

  setup do
    TestBackend.reset!()
    Application.put_env(:ash_remote, :base_url, TestBackend.base_url())
    Application.put_env(:ash_remote, :realtime_test_sink, self())

    {:ok, sup} =
      start_supervised(
        {AshRemote.Realtime,
         name: __MODULE__.Realtime, resources: [ClientTodo, SecondTodo], base_url: @socket_base}
      )

    AshRemote.Realtime.listen_lifecycle(__MODULE__.Realtime)
    assert_receive {AshRemote.Realtime, %{type: :connected}}, 2_000

    on_exit(fn ->
      Application.delete_env(:ash_remote, :base_url)
      Application.delete_env(:ash_remote, :realtime_test_sink)
    end)

    %{sup: sup}
  end

  test "a server-side create is replicated to BOTH resources sharing the source" do
    server_todo = Ash.create!(AshRemote.Backend.Todo, %{title: "Buy milk", status: :pending})

    # Two notifications — one per client resource mapped to the same source.
    assert_receive {:notification, n1}, 2_000
    assert_receive {:notification, n2}, 2_000

    resources = Enum.map([n1, n2], & &1.resource) |> Enum.sort_by(&inspect/1)
    assert resources == Enum.sort_by([ClientTodo, SecondTodo], &inspect/1)

    for n <- [n1, n2] do
      assert n.action.type == :create
      assert n.data.id == server_todo.id
      assert n.data.title == "Buy milk"
    end
  end
end
