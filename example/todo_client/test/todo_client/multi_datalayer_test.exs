defmodule TodoClient.MultiDatalayerTest do
  @moduledoc """
  The proof: the client's generated resources run an ETS cache over
  `AshRemote.DataLayer`. Wire silence is asserted with an RPC-counting
  router; cache semantics are asserted via `ash_multi_datalayer` telemetry.
  Every call carries `actor: actor()` since (unlike `ash_multi_datalayer`'s
  own example) this server enforces an owner-or-public policy — the JWT
  the actor carries is what makes each `/rpc/run` call authorized at all.
  """
  use TodoClient.Case, async: false

  defp actor, do: TodoClient.Session.actor()
  defp rpc, do: CountingRouter.rpc_count()

  describe "T1: repeated identical reads" do
    test "the second read never touches the server", %{list: list} do
      server_create_todo!(%{title: "Walk the dog", list_id: list.id})

      query = Ash.Query.filter(Todo, list_id == ^list.id)

      assert [%{title: "Walk the dog"}] = Ash.read!(query, actor: actor())
      assert_receive {:mdl, [_, :read, :miss], _, %{reason: :no_coverage_entry}}
      assert_receive {:mdl, [_, :read, :backfill], _, _}
      after_first = rpc()

      assert [%{title: "Walk the dog"}] = Ash.read!(query, actor: actor())
      assert rpc() == after_first
      assert_receive {:mdl, [_, :read, :hit], _, _}
    end
  end

  describe "T2: filter subsumption" do
    test "a narrower filter is served by broader coverage without an RPC", %{list: list} do
      server_create_todo!(%{title: "Active task", list_id: list.id})
      server_create_todo!(%{title: "Done task", list_id: list.id, completed: true})

      assert [_, _] = Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor())
      warm = rpc()

      assert [%{title: "Active task"}] =
               Todo
               |> Ash.Query.filter(list_id == ^list.id and completed == false)
               |> Ash.read!(actor: actor())

      assert rpc() == warm
      assert_receive {:mdl, [_, :read, :hit], _, _}
    end

    test "negative control: a non-contained filter falls through", %{
      list: list,
      other_list: other_list
    } do
      server_create_todo!(%{title: "Here", list_id: list.id})
      server_create_todo!(%{title: "There", list_id: other_list.id})

      Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor())
      warm = rpc()

      assert [%{title: "There"}] =
               Todo |> Ash.Query.filter(list_id == ^other_list.id) |> Ash.read!(actor: actor())

      assert rpc() == warm + 1
    end
  end

  describe "T3: write-through with the server's returned record" do
    test "creates carry server-computed defaults into the cache", %{list: list} do
      Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor())

      created =
        Todo
        |> Ash.Changeset.for_create(:create, %{title: "Fresh", list_id: list.id}, actor: actor())
        |> Ash.create!(actor: actor())

      assert created.completed == false
      assert created.priority == :medium
      assert created.inserted_at

      assert_receive {:mdl, [_, :ledger, :invalidated], _, _}
      before_read = rpc()

      assert [%{title: "Fresh"}] =
               Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor())

      assert rpc() == before_read + 1
      warm = rpc()

      assert [%{title: "Fresh", completed: false, priority: :medium, inserted_at: %DateTime{}}] =
               Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor())

      assert rpc() == warm
    end
  end

  describe "T4: row-aware invalidation" do
    test "an update drops only coverage matching the changed row", %{
      list: list,
      other_list: other_list
    } do
      server_create_todo!(%{title: "Here", list_id: list.id})
      server_create_todo!(%{title: "There", list_id: other_list.id})

      here = Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor()) |> hd()
      Todo |> Ash.Query.filter(list_id == ^other_list.id) |> Ash.read!(actor: actor())
      warm = rpc()

      here
      |> Ash.Changeset.for_update(:update, %{title: "Here (edited)"}, actor: actor())
      |> Ash.update!(actor: actor())

      assert [%{title: "Here (edited)"}] =
               Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor())

      assert rpc() == warm + 2

      assert [%{title: "There"}] =
               Todo |> Ash.Query.filter(list_id == ^other_list.id) |> Ash.read!(actor: actor())

      assert rpc() == warm + 2
    end

    test "a row moving INTO a cached filter invalidates it", %{list: list} do
      server_create_todo!(%{title: "Open", list_id: list.id})

      assert [] =
               Todo
               |> Ash.Query.filter(list_id == ^list.id and completed == true)
               |> Ash.read!(actor: actor())

      todo = Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor()) |> hd()

      todo
      |> Ash.Changeset.for_update(:update, %{completed: true}, actor: actor())
      |> Ash.update!(actor: actor())

      assert [%{title: "Open", completed: true}] =
               Todo
               |> Ash.Query.filter(list_id == ^list.id and completed == true)
               |> Ash.read!(actor: actor())
    end
  end

  describe "T5: mirrored calc evaluated locally; aggregate fold vs. forward" do
    test "overdue? is computed from the cache with no RPC (local evaluation)", %{list: list} do
      server_create_todo!(%{title: "Late", list_id: list.id, due_date: ~D[2020-01-01]})
      server_create_todo!(%{title: "Future", list_id: list.id, due_date: ~D[2099-01-01]})

      Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor())
      warm = rpc()

      todos =
        Todo
        |> Ash.Query.filter(list_id == ^list.id)
        |> Ash.Query.load(:overdue?)
        |> Ash.read!(actor: actor())
        |> Map.new(&{&1.title, &1.overdue?})

      assert rpc() == warm
      assert todos == %{"Late" => true, "Future" => false}
    end

    test "todo_count folds from the cache (0 RPC); completed_count is forwarded to the server",
         %{list: list} do
      server_create_todo!(%{title: "One", list_id: list.id})
      server_create_todo!(%{title: "Done", list_id: list.id, completed: true})

      TodoList |> Ash.Query.filter(id == ^list.id) |> Ash.read!(actor: actor())
      Todo |> Ash.Query.filter(list_id == ^list.id) |> Ash.read!(actor: actor())
      warm = rpc()

      assert [%{todo_count: 2}] =
               TodoList
               |> Ash.Query.filter(id == ^list.id)
               |> Ash.Query.load(:todo_count)
               |> Ash.read!(actor: actor())

      assert rpc() == warm

      assert [%{completed_count: 1}] =
               TodoList
               |> Ash.Query.filter(id == ^list.id)
               |> Ash.Query.load(:completed_count)
               |> Ash.read!(actor: actor())

      assert rpc() > warm

      server_create_todo!(%{title: "Also done", list_id: list.id, completed: true})

      assert [%{completed_count: 2}] =
               TodoList
               |> Ash.Query.filter(id == ^list.id)
               |> Ash.Query.load(:completed_count)
               |> Ash.read!(actor: actor())
    end
  end

  describe "T7: kill-switch" do
    test "disable! routes around the cache; re-enable resumes hits", %{list: list} do
      server_create_todo!(%{title: "Steady", list_id: list.id})

      query = Ash.Query.filter(Todo, list_id == ^list.id)
      Ash.read!(query, actor: actor())
      Ash.read!(query, actor: actor())
      warm = rpc()

      AshMultiDatalayer.disable!(Todo)

      try do
        Ash.read!(query, actor: actor())
        Ash.read!(query, actor: actor())
        assert rpc() == warm + 2

        server_create_todo!(%{title: "Live", list_id: list.id})
        assert length(Ash.read!(query, actor: actor())) == 2

        # A write while disabled still invalidates coverage: no pre-switch
        # entries may survive to serve stale hits after re-enable.
        todo = query |> Ash.read!(actor: actor()) |> Enum.find(&(&1.title == "Steady"))

        todo
        |> Ash.Changeset.for_update(:update, %{title: "Steady (edited)"}, actor: actor())
        |> Ash.update!(actor: actor())

        assert AshMultiDatalayer.Debug.dump_ledger(Todo) == []
      after
        AshMultiDatalayer.enable!(Todo)
      end

      before_warm = rpc()
      Ash.read!(query, actor: actor())
      assert rpc() == before_warm + 1
      titles = Ash.read!(query, actor: actor()) |> Enum.map(& &1.title) |> Enum.sort()
      assert rpc() == before_warm + 1
      assert titles == ["Live", "Steady (edited)"]
    end
  end
end
