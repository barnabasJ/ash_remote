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
    # Publish the manifest fresh from the backend (backend → manifest → generate).
    {:ok, spec} =
      Ash.Info.Manifest.generate(
        otp_app: :ash_remote,
        action_entrypoints: [
          {AshRemote.Backend.Todo, :read},
          {AshRemote.Backend.Todo, :get_by_id},
          {AshRemote.Backend.Todo, :create},
          {AshRemote.Backend.Todo, :update},
          {AshRemote.Backend.Todo, :complete},
          {AshRemote.Backend.Todo, :destroy},
          {AshRemote.Backend.User, :read},
          {AshRemote.Backend.User, :create},
          {AshRemote.Backend.Comment, :read},
          {AshRemote.Backend.Comment, :create}
        ]
      )

    {:ok, json} = Ash.Info.Manifest.JsonSerializer.to_json(spec)
    path = Path.join(System.tmp_dir!(), "ash_remote_e2e_manifest.json")
    File.write!(path, json)

    manifest = AshRemote.Manifest.Loader.load!(path)
    modules = AshRemote.Gen.generate(manifest, namespace: @namespace)

    # Compile the generated resources (the "compiles anywhere" guarantee).
    source = modules |> Enum.map(fn {_m, s} -> s end) |> Enum.join("\n")
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

  test "update, custom action, and destroy round-trip" do
    %{todo: todo} = seed()

    assert Ash.update!(todo, %{title: "Write more"}).title == "Write more"
    assert Ash.update!(todo, %{}, action: :complete).completed == true

    assert :ok = Ash.destroy!(todo)
    assert [] == mod(:Todo) |> Ash.Query.filter(id == ^todo.id) |> Ash.read!()
  end

  test "get by primary key" do
    %{todo: todo} = seed()
    assert Ash.get!(mod(:Todo), todo.id).id == todo.id
  end
end
