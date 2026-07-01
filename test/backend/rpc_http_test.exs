defmodule AshRemote.Backend.RpcHttpTest do
  @moduledoc "M0: the reference backend serves the RPC protocol over real HTTP."
  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshRemote.Backend.TestBackend

  @todo "AshRemote.Backend.Todo"
  @user "AshRemote.Backend.User"

  setup do
    TestBackend.reset!()
    :ok
  end

  defp run(body), do: Req.post!(TestBackend.base_url() <> "/rpc/run", json: body).body

  test "create → read-with-nested-loads round-trips over HTTP" do
    %{"success" => true, "data" => %{"id" => user_id}} =
      run(%{
        "resource" => @user,
        "action" => "create",
        "input" => %{"name" => "Ada", "email" => "ada@example.com"},
        "fields" => ["id"]
      })

    %{"success" => true, "data" => %{"id" => todo_id}} =
      run(%{
        "resource" => @todo,
        "action" => "create",
        "input" => %{"title" => "Write code", "status" => "doing", "user_id" => user_id},
        "fields" => ["id"]
      })

    resp =
      run(%{
        "resource" => @todo,
        "action" => "read",
        "filter" => %{"id" => %{"eq" => todo_id}},
        "fields" => [
          "id",
          "title",
          "is_overdue",
          %{"comment_count" => []},
          %{"user" => ["name"]}
        ]
      })

    assert %{"success" => true, "data" => [todo]} = resp
    assert todo["title"] == "Write code"
    assert todo["is_overdue"] == false
    assert todo["comment_count"] == 0
    assert todo["user"] == %{"name" => "Ada"}
  end

  test "validate reports typed required errors" do
    resp =
      Req.post!(TestBackend.base_url() <> "/rpc/validate",
        json: %{"resource" => @todo, "action" => "create", "input" => %{}}
      ).body

    assert %{"success" => false, "errors" => [%{"type" => "required"} | _]} = resp
  end

  test "unknown resource is a typed error" do
    assert %{"success" => false, "errors" => [%{"type" => "unknown_resource"}]} =
             run(%{"resource" => "AshRemote.Backend.Nope", "action" => "read", "fields" => ["id"]})
  end
end
