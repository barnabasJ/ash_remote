defmodule AshRemote.ProtocolTest do
  use ExUnit.Case, async: true

  alias AshRemote.Protocol

  describe "build_run/1" do
    test "stringifies resource/action and drops nil keys" do
      body =
        Protocol.build_run(%{
          resource: AshRemote.Backend.Todo,
          action: :read,
          fields: ["id", "title"],
          filter: %{"id" => %{"eq" => "x"}}
        })

      assert body == %{
               "resource" => "AshRemote.Backend.Todo",
               "action" => "read",
               "fields" => ["id", "title"],
               "filter" => %{"id" => %{"eq" => "x"}}
             }

      refute Map.has_key?(body, "input")
      refute Map.has_key?(body, "page")
    end
  end

  describe "build_validate/1" do
    test "keeps resource/action/input, drops read-only keys" do
      body =
        Protocol.build_validate(%{
          resource: "R",
          action: "create",
          input: %{"a" => 1},
          fields: ["id"],
          filter: %{}
        })

      assert body == %{"resource" => "R", "action" => "create", "input" => %{"a" => 1}}
    end
  end

  describe "parse_run/1" do
    test "success returns data" do
      assert {:ok, [%{"id" => 1}]} =
               Protocol.parse_run(%{"success" => true, "data" => [%{"id" => 1}]})
    end

    test "failure returns errors" do
      assert {:error, [%{"type" => "required"}]} =
               Protocol.parse_run(%{"success" => false, "errors" => [%{"type" => "required"}]})
    end

    # M11: an explicit `data: null` (a legitimate get?/single-target miss)
    # must stay distinguishable from `data` being entirely absent (a
    # malformed success response) — collapsing both to the same {:ok, nil}
    # makes the decoder unable to tell them apart downstream.
    test "an explicit null data is a legitimate success" do
      assert {:ok, nil} = Protocol.parse_run(%{"success" => true, "data" => nil})
    end

    test "a missing data key is a malformed response, not a legitimate null" do
      assert {:error, [%{"type" => "framework"}]} = Protocol.parse_run(%{"success" => true})
    end
  end

  describe "parse_validate/1" do
    test "ok on success and empty errors" do
      assert :ok = Protocol.parse_validate(%{"success" => true})
      assert :ok = Protocol.parse_validate(%{"success" => false, "errors" => []})
    end

    test "error on failure" do
      assert {:error, [_]} =
               Protocol.parse_validate(%{"success" => false, "errors" => [%{"type" => "x"}]})
    end
  end

  test "parse_run against committed fixtures" do
    for {name, kind} <- [
          {"read_nested", :ok},
          {"read_list", :ok},
          {"create_todo", :ok},
          {"error_invalid", :error},
          {"error_unknown_resource", :error}
        ] do
      %{"response" => response} = read_fixture(name)

      case kind do
        :ok -> assert {:ok, _} = Protocol.parse_run(response)
        :error -> assert {:error, [_ | _]} = Protocol.parse_run(response)
      end
    end
  end

  defp read_fixture(name) do
    "test/support/fixtures/protocol/#{name}.json" |> File.read!() |> Jason.decode!()
  end
end
