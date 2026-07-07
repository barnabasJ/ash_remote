defmodule AshRemote.Backend.RpcFieldPolicyTest do
  @moduledoc """
  B1: `public? false` calculations/aggregates must never be selectable or
  serializable over the RPC wire, on any response path (top-level read,
  nested relationship selection, create, update).
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshRemote.Backend.TestBackend

  @todo "AshRemote.Backend.Todo"

  setup do
    TestBackend.reset!()
    :ok
  end

  defp run(body), do: Req.post!(TestBackend.base_url() <> "/rpc/run", json: body).body

  defp create_todo!(title \\ "Write code") do
    %{"success" => true, "data" => %{"id" => id}} =
      run(%{
        "resource" => @todo,
        "action" => "create",
        "input" => %{"title" => title, "status" => "doing"},
        "fields" => ["id"]
      })

    id
  end

  test "read: private calculation and aggregate are omitted, public ones still resolve" do
    todo_id = create_todo!()

    resp =
      run(%{
        "resource" => @todo,
        "action" => "read",
        "filter" => %{"id" => %{"eq" => todo_id}},
        "fields" => [
          "id",
          "is_overdue",
          "comment_count",
          "internal_risk_score",
          "internal_comment_count"
        ]
      })

    assert %{"success" => true, "data" => [todo]} = resp
    refute Map.has_key?(todo, "internal_risk_score")
    refute Map.has_key?(todo, "internal_comment_count")
    assert todo["is_overdue"] == false
    assert todo["comment_count"] == 0
  end

  test "create response omits a requested private calculation/aggregate" do
    resp =
      run(%{
        "resource" => @todo,
        "action" => "create",
        "input" => %{"title" => "Write code", "status" => "doing"},
        "fields" => ["id", "internal_risk_score", "internal_comment_count"]
      })

    assert %{"success" => true, "data" => todo} = resp
    refute Map.has_key?(todo, "internal_risk_score")
    refute Map.has_key?(todo, "internal_comment_count")
  end

  test "update response omits a requested private calculation/aggregate" do
    todo_id = create_todo!()

    resp =
      run(%{
        "resource" => @todo,
        "action" => "update",
        "primary_key" => %{"id" => todo_id},
        "input" => %{"title" => "Write more code"},
        "fields" => ["id", "internal_risk_score", "internal_comment_count"]
      })

    assert %{"success" => true, "data" => todo} = resp
    refute Map.has_key?(todo, "internal_risk_score")
    refute Map.has_key?(todo, "internal_comment_count")
  end

  test "nested relationship selection omits a requested private calculation" do
    parent_id = create_todo!("Parent")

    %{"success" => true} =
      run(%{
        "resource" => @todo,
        "action" => "create",
        "input" => %{"title" => "Child", "status" => "doing", "parent_id" => parent_id},
        "fields" => ["id"]
      })

    resp =
      run(%{
        "resource" => @todo,
        "action" => "read",
        "filter" => %{"id" => %{"eq" => parent_id}},
        "fields" => ["id", %{"subtasks" => ["id", "title", "internal_risk_score"]}]
      })

    assert %{"success" => true, "data" => [todo]} = resp
    assert [subtask] = todo["subtasks"]
    assert subtask["title"] == "Child"
    refute Map.has_key?(subtask, "internal_risk_score")
  end

  test "retained regression: private attribute is omitted (#1 private-attribute half, fixed in an earlier run)" do
    todo_id = create_todo!()

    resp =
      run(%{
        "resource" => @todo,
        "action" => "read",
        "filter" => %{"id" => %{"eq" => todo_id}},
        "fields" => ["id", "title", "internal_notes"]
      })

    assert %{"success" => true, "data" => [todo]} = resp
    refute Map.has_key?(todo, "internal_notes")
  end
end
