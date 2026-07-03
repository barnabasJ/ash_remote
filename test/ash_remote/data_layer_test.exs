defmodule AshRemote.DataLayerTest do
  @moduledoc "M2 walking skeleton: the hand-written mirror round-trips CRUD + loads over RPC."
  use ExUnit.Case, async: false
  @moduletag :integration

  require Ash.Query

  alias AshRemote.Backend.TestBackend
  alias AshRemote.Client.{Comment, Todo, User}

  setup do
    TestBackend.reset!()

    Application.put_env(:ash_remote, :remote_config, %{
      User => %{base_url: TestBackend.base_url(), source: "AshRemote.Backend.User"},
      Todo => %{base_url: TestBackend.base_url(), source: "AshRemote.Backend.Todo"},
      Comment => %{base_url: TestBackend.base_url(), source: "AshRemote.Backend.Comment"}
    })

    on_exit(fn -> Application.delete_env(:ash_remote, :remote_config) end)
    :ok
  end

  defp seed do
    user = Ash.create!(User, %{name: "Ada", email: "ada@example.com"})
    todo = Ash.create!(Todo, %{title: "Write code", status: :doing, user_id: user.id})
    _c = Ash.create!(Comment, %{body: "nice", todo_id: todo.id, user_id: user.id})
    %{user: user, todo: todo}
  end

  test "create returns a decoded struct" do
    user = Ash.create!(User, %{name: "Grace", email: "grace@example.com"})
    assert %User{name: "Grace"} = user
    assert is_binary(user.id)
  end

  test "read returns decoded structs" do
    seed()
    assert [%Todo{title: "Write code", status: :doing}] = Ash.read!(Todo)
  end

  test "filter is pushed to the backend" do
    %{todo: todo} = seed()
    Ash.create!(Todo, %{title: "Other", user_id: nil})

    results = Todo |> Ash.Query.filter(id == ^todo.id) |> Ash.read!()
    assert [%Todo{id: id}] = results
    assert id == todo.id
  end

  test "sort is pushed to the backend" do
    seed()
    Ash.create!(Todo, %{title: "Aaa", user_id: nil})

    titles = Todo |> Ash.Query.sort(title: :asc) |> Ash.read!() |> Enum.map(& &1.title)
    assert titles == ["Aaa", "Write code"]
  end

  test "limit is pushed to the backend" do
    seed()
    Ash.create!(Todo, %{title: "Two", user_id: nil})
    assert [_one] = Todo |> Ash.Query.limit(1) |> Ash.read!()
  end

  test "loads aggregate, calculation (with + without args), and relationship in one read" do
    %{todo: todo} = seed()

    loaded =
      Todo
      |> Ash.Query.filter(id == ^todo.id)
      |> Ash.Query.load([
        :comment_count,
        :is_overdue,
        {:title_with_prefix, %{prefix: "TODO: "}},
        :user
      ])
      |> Ash.read_one!()

    assert loaded.comment_count == 1
    assert loaded.is_overdue == false
    # NB: the backend's :string calc argument trims trailing whitespace.
    assert loaded.title_with_prefix == "TODO:Write code"
    assert %User{name: "Ada"} = loaded.user
  end

  test "update round-trips" do
    %{todo: todo} = seed()
    updated = Ash.update!(todo, %{title: "Write more code"})
    assert updated.title == "Write more code"
    assert Ash.get!(Todo, todo.id).title == "Write more code"
  end

  test "update toggles a boolean attribute over the wire" do
    %{todo: todo} = seed()
    completed = Ash.update!(todo, %{completed: true})
    assert completed.completed == true
    assert Ash.get!(Todo, todo.id).completed == true
  end

  test "destroy round-trips" do
    %{todo: todo} = seed()
    assert :ok = Ash.destroy!(todo)
    assert [] == Todo |> Ash.Query.filter(id == ^todo.id) |> Ash.read!()
  end

  test "get by primary key (read + pk filter)" do
    %{todo: todo} = seed()
    assert %Todo{id: id} = Ash.get!(Todo, todo.id)
    assert id == todo.id
  end

  # User's backend read has no pagination — Ash.get/2's internal `limit: 2`
  # must land as a plain query limit, not a page option, on such actions.
  test "get and limit work against a backend read without pagination" do
    %{user: user} = seed()
    assert %User{name: "Ada"} = Ash.get!(User, user.id)

    Ash.create!(User, %{name: "Grace", email: "grace@example.com"})
    assert [_only_one] = User |> Ash.Query.limit(1) |> Ash.read!()
  end
end
