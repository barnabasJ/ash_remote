defmodule AshRemote.RemoteLoadTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  require Ash.Query

  alias AshRemote.Backend.TestBackend
  @namespace "AshRemote.RlGen"

  setup_all do
    path = Path.join(System.tmp_dir!(), "ash_remote_rl_manifest.json")
    File.write!(path, AshRemote.Server.manifest_json(:ash_remote))
    manifest = AshRemote.Manifest.Loader.load!(path)
    modules = AshRemote.Gen.generate(manifest, namespace: @namespace)
    Code.compile_string(modules |> Enum.map(& &1.source) |> Enum.join("\n"))
    :ok
  end

  setup do
    TestBackend.reset!()
    Application.put_env(:ash_remote, :base_url, TestBackend.base_url())
    on_exit(fn -> Application.delete_env(:ash_remote, :base_url) end)
    :ok
  end

  defp mod(name), do: Module.concat(@namespace, name)

  test "loading a remote() calc returns the real server value" do
    u = Ash.create!(mod(:User), %{name: "Ada", email: "ada@example.com"})
    has = Ash.create!(mod(:Todo), %{title: "HasComment", user_id: u.id})
    _none = Ash.create!(mod(:Todo), %{title: "NoComment", user_id: u.id})
    _c = Ash.create!(mod(:Comment), %{body: "nice", todo_id: has.id, user_id: u.id})

    TestBackend.reset_rpc_count!()

    result =
      mod(:Todo)
      |> Ash.Query.load(:comment_count)
      |> Ash.read!()
      |> Map.new(&{&1.title, &1.comment_count})

    assert result == %{"HasComment" => 1, "NoComment" => 0}
    assert TestBackend.rpc_count() == 1
  end

  test "filter on a remote() calc pushes to server (one RPC)" do
    u = Ash.create!(mod(:User), %{name: "Ada", email: "ada@example.com"})
    has = Ash.create!(mod(:Todo), %{title: "HasComment", user_id: u.id})
    _none = Ash.create!(mod(:Todo), %{title: "NoComment", user_id: u.id})
    _c = Ash.create!(mod(:Comment), %{body: "nice", todo_id: has.id, user_id: u.id})
    TestBackend.reset_rpc_count!()

    assert ["HasComment"] =
             mod(:Todo)
             |> Ash.Query.filter(comment_count > 0)
             |> Ash.read!()
             |> Enum.map(& &1.title)

    assert TestBackend.rpc_count() == 1
    assert [] = mod(:Todo) |> Ash.Query.filter(comment_count > 5) |> Ash.read!()
  end

  test "sort on a remote() calc" do
    u = Ash.create!(mod(:User), %{name: "Ada", email: "ada@example.com"})
    has = Ash.create!(mod(:Todo), %{title: "HasComment", user_id: u.id})
    _none = Ash.create!(mod(:Todo), %{title: "NoComment", user_id: u.id})
    _c = Ash.create!(mod(:Comment), %{body: "nice", todo_id: has.id, user_id: u.id})

    try do
      titles =
        mod(:Todo)
        |> Ash.Query.sort(comment_count: :desc)
        |> Ash.read!()
        |> Enum.map(& &1.title)

      assert ["HasComment", "NoComment"] = titles
    rescue
      e -> flunk("SORT RAISED: #{Exception.message(e) |> String.slice(0, 250)}")
    end
  end

  test "loading a parameterized remote() calc returns the real server value (args forwarded)" do
    _u = Ash.create!(mod(:User), %{name: "Ada", email: "ada@example.com"})
    _t = Ash.create!(mod(:Todo), %{title: "Write code"})
    TestBackend.reset_rpc_count!()

    [loaded] =
      mod(:Todo)
      |> Ash.Query.load(title_with_prefix: %{prefix: "P:"})
      |> Ash.read!()

    assert loaded.title_with_prefix == "P:Write code"
    assert TestBackend.rpc_count() == 1
  end

  test "filter on a parameterized remote() calc pushes to server (not inlined to the pk)" do
    _u = Ash.create!(mod(:User), %{name: "Ada", email: "ada@example.com"})
    _hit = Ash.create!(mod(:Todo), %{title: "Write code"})
    _miss = Ash.create!(mod(:Todo), %{title: "Something else"})
    TestBackend.reset_rpc_count!()

    titles =
      mod(:Todo)
      |> Ash.Query.filter(title_with_prefix(prefix: "P:") == "P:Write code")
      |> Ash.read!()
      |> Enum.map(& &1.title)

    assert titles == ["Write code"]
    assert TestBackend.rpc_count() == 1
  end

  test "sort on a remote calc is forwarded, surfacing the backend's own sortability" do
    # `title_with_prefix` is a module calculation on the server (no expression),
    # so the *backend itself* cannot sort on it (Ash requires an expression to
    # sort). The client forwards the sort faithfully and surfaces that error,
    # rather than silently sorting on the wrong field or fetching everything to
    # sort in memory. (Aggregates like `comment_count` are sortable — see above.)
    _u = Ash.create!(mod(:User), %{name: "Ada", email: "ada@example.com"})
    _b = Ash.create!(mod(:Todo), %{title: "Bbb"})

    assert_raise Ash.Error.Unknown, fn ->
      mod(:Todo)
      |> Ash.Query.sort([{:title_with_prefix, {%{prefix: "P:"}, :asc}}])
      |> Ash.read!()
    end
  end
end
