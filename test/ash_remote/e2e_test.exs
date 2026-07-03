defmodule AshRemote.E2ETest do
  @moduledoc """
  M6 end-to-end: publish a manifest from the backend, generate standalone client
  resources, compile them, and drive full CRUD + loads over RPC against the live
  backend — asserting parity with the hand-written M2 mirror.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  require Ash.Query
  alias AshRemote.Backend.TestBackend

  @namespace "AshRemote.E2EGen"

  setup_all do
    # Publish the manifest fresh from the backend's `rpc do` exposure block
    # (backend → manifest → generate), exactly as the RPC server does.
    path = Path.join(System.tmp_dir!(), "ash_remote_e2e_manifest.json")
    File.write!(path, AshRemote.Server.manifest_json(:ash_remote))

    manifest = AshRemote.Manifest.Loader.load!(path)
    modules = AshRemote.Gen.generate(manifest, namespace: @namespace)

    # Compile the generated resources (the "compiles anywhere" guarantee).
    source = modules |> Enum.map(& &1.source) |> Enum.join("\n")
    Code.compile_string(source)

    :ok
  end

  setup do
    TestBackend.reset!()
    Application.put_env(:ash_remote, :base_url, TestBackend.base_url())
    on_exit(fn -> Application.delete_env(:ash_remote, :base_url) end)
    :ok
  end

  defp mod(name), do: Module.concat(@namespace, name)

  defp seed do
    user = Ash.create!(mod(:User), %{name: "Ada", email: "ada@example.com"})
    todo = Ash.create!(mod(:Todo), %{title: "Write code", status: :doing, user_id: user.id})
    _c = Ash.create!(mod(:Comment), %{body: "nice", todo_id: todo.id, user_id: user.id})
    %{user: user, todo: todo}
  end

  test "generated resources compiled and are on the remote data layer" do
    assert Ash.DataLayer.data_layer(mod(:Todo)) == AshRemote.DataLayer
    assert AshRemote.Resource.Info.remote_source!(mod(:Todo)) == "AshRemote.Backend.Todo"
  end

  test "create + read with enum/calc/aggregate/relationship loads round-trips" do
    %{todo: todo} = seed()

    loaded =
      mod(:Todo)
      |> Ash.Query.filter(id == ^todo.id)
      |> Ash.Query.load([
        :comment_count,
        :is_overdue,
        {:title_with_prefix, %{prefix: "P:"}},
        :user
      ])
      |> Ash.read_one!()

    assert loaded.title == "Write code"
    assert loaded.status == :doing
    assert loaded.comment_count == 1
    assert loaded.is_overdue == false
    assert loaded.title_with_prefix == "P:Write code"
    assert loaded.user.name == "Ada"
  end

  test "self-referential relationship with a non-conventional FK round-trips" do
    parent = Ash.create!(mod(:Todo), %{title: "Ship it"})
    _sub1 = Ash.create!(mod(:Todo), %{title: "Write changelog", parent_id: parent.id})
    _sub2 = Ash.create!(mod(:Todo), %{title: "Tag release", parent_id: parent.id})

    loaded =
      mod(:Todo)
      |> Ash.Query.filter(id == ^parent.id)
      |> Ash.Query.load(:subtasks)
      |> Ash.read_one!()

    assert loaded.subtasks |> Enum.map(& &1.title) |> Enum.sort() ==
             ["Tag release", "Write changelog"]

    sub =
      mod(:Todo)
      |> Ash.Query.filter(title == "Tag release")
      |> Ash.Query.load(:parent)
      |> Ash.read_one!()

    assert sub.parent.title == "Ship it"
  end

  test "filter and sort are pushed to the backend" do
    seed()
    Ash.create!(mod(:Todo), %{title: "Aaa"})

    titles =
      mod(:Todo) |> Ash.Query.sort(title: :asc) |> Ash.read!() |> Enum.map(& &1.title)

    assert titles == ["Aaa", "Write code"]

    only =
      mod(:Todo)
      |> Ash.Query.filter(title == "Aaa")
      |> Ash.read!()
      |> Enum.map(& &1.title)

    assert only == ["Aaa"]
  end

  test "update and destroy round-trip" do
    %{todo: todo} = seed()

    assert Ash.update!(todo, %{title: "Write more"}).title == "Write more"
    assert Ash.update!(todo, %{completed: true}).completed == true

    assert :ok = Ash.destroy!(todo)
    assert [] == mod(:Todo) |> Ash.Query.filter(id == ^todo.id) |> Ash.read!()
  end

  test "get by primary key" do
    %{todo: todo} = seed()
    assert Ash.get!(mod(:Todo), todo.id).id == todo.id
  end

  test "mirrored validations run client-side, without a round trip" do
    # Unreachable backend: if the error is a validation error (not a transport
    # error), it was produced client-side before any HTTP request.
    Application.put_env(:ash_remote, :base_url, "http://127.0.0.1:1")

    assert {:error, %Ash.Error.Invalid{} = error} = Ash.create(mod(:Todo), %{title: "ab"})
    assert Exception.message(error) =~ "must have length of at least 3"

    assert {:error, %Ash.Error.Invalid{} = error} = Ash.create(mod(:Todo), %{title: "!nope"})
    assert Exception.message(error) =~ "must match"
  end

  test "valid input passes the mirrored validations and round-trips" do
    assert %{title: "Big"} = Ash.create!(mod(:Todo), %{title: "Big"})
  end

  describe "remote calculations" do
    test "mirrored and proxied calcs are all expression calcs so the backend can filter and sort" do
      assert {Ash.Resource.Calculation.Expression, _opts} =
               Ash.Resource.Info.calculation(mod(:Todo), :is_overdue).calculation

      # Proxied calcs (including aggregates) are emitted as `remote(...)`
      # expression calcs so the backend can filter and sort on them.
      assert {Ash.Resource.Calculation.Expression, _opts} =
               Ash.Resource.Info.calculation(mod(:Todo), :comment_count).calculation

      # Parameterized proxied calcs are also `remote(...)` expression calcs; their
      # arguments flow through to the `/rpc/run` call so the backend computes the
      # value with the given args.
      assert {Ash.Resource.Calculation.Expression, _opts} =
               Ash.Resource.Info.calculation(mod(:Todo), :title_with_prefix).calculation
    end

    test "remote calculations loaded through a read resolve in one request total" do
      # Both are `remote(...)` expression calcs, so Ash keeps them in the query
      # and the data layer folds them into the same `/rpc/run` (loaded by name,
      # with parameterized args forwarded) — one request for all of them.
      %{todo: todo} = seed()
      TestBackend.reset_rpc_count!()

      loaded =
        mod(:Todo)
        |> Ash.Query.filter(id == ^todo.id)
        |> Ash.Query.load([:comment_count, {:title_with_prefix, %{prefix: "P:"}}])
        |> Ash.read_one!()

      assert loaded.comment_count == 1
      assert loaded.title_with_prefix == "P:Write code"
      assert TestBackend.rpc_count() == 1
    end

    test "standalone Ash.load resolves all remote calculations" do
      %{todo: todo} = seed()
      [record] = mod(:Todo) |> Ash.Query.filter(id == ^todo.id) |> Ash.read!()
      TestBackend.reset_rpc_count!()

      loaded = Ash.load!(record, [:comment_count, {:title_with_prefix, %{prefix: "B:"}}])

      assert loaded.comment_count == 1
      assert loaded.title_with_prefix == "B:Write code"

      # Both calcs are now `remote(...)` expression calcs, so a standalone
      # `Ash.load` resolves them in a single re-read through the data layer.
      assert TestBackend.rpc_count() == 1
    end

    test "filtering on a mirrored expression calculation runs REAL semantics" do
      # The old placeholder (`expr(not is_nil(id))`) would have matched every
      # todo here — filtering on a calc inlines its expression, and mirrored
      # expressions make that correct instead of silently wrong.
      seed()
      Ash.create!(mod(:Todo), %{title: "Very late", due_date: ~D[2020-01-01]})

      assert ["Very late"] =
               mod(:Todo)
               |> Ash.Query.filter(is_overdue == true)
               |> Ash.read!()
               |> Enum.map(& &1.title)
    end

    test "filtering on a proxied calculation is pushed to the backend" do
      # `comment_count` is emitted as a `remote(...)` expression calc, so Ash
      # keeps it in the query and the filter reduces to the calc name on the
      # wire — the backend evaluates it with real semantics in one request. We
      # never fetch rows to filter in memory.
      %{todo: todo} = seed()
      TestBackend.reset_rpc_count!()

      assert [%{id: filtered_id}] =
               mod(:Todo) |> Ash.Query.filter(comment_count > 0) |> Ash.read!()

      assert filtered_id == todo.id
      assert TestBackend.rpc_count() == 1
    end
  end
end
