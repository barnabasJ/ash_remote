defmodule AshRemote.TopicsTest do
  use ExUnit.Case, async: true

  alias AshRemote.Topics

  doctest AshRemote.Topics

  describe "topic/2" do
    test "without a tenant" do
      assert Topics.topic("TodoServer.Todo") == "ash_remote:TodoServer.Todo"
    end

    test "with a tenant" do
      assert Topics.topic("TodoServer.Todo", "org_1") == "ash_remote:TodoServer.Todo:org_1"
    end

    test "nil tenant is the same as none" do
      assert Topics.topic("TodoServer.Todo", nil) == Topics.topic("TodoServer.Todo")
    end

    test "stringifies a non-binary tenant" do
      assert Topics.topic("TodoServer.Todo", 42) == "ash_remote:TodoServer.Todo:42"
    end
  end

  describe "parse/1" do
    test "round-trips a tenantless topic" do
      assert Topics.parse(Topics.topic("TodoServer.Todo")) == {:ok, "TodoServer.Todo", nil}
    end

    test "round-trips a tenanted topic" do
      assert Topics.parse(Topics.topic("TodoServer.Todo", "org_1")) ==
               {:ok, "TodoServer.Todo", "org_1"}
    end

    test "a tenant may itself contain colons (remainder is kept whole)" do
      assert Topics.parse("ash_remote:TodoServer.Todo:a:b:c") ==
               {:ok, "TodoServer.Todo", "a:b:c"}
    end

    test "rejects a wrong prefix" do
      assert Topics.parse("other:TodoServer.Todo") == :error
    end

    test "rejects a missing source" do
      assert Topics.parse("ash_remote:") == :error
    end

    test "rejects an empty tenant segment" do
      assert Topics.parse("ash_remote:TodoServer.Todo:") == :error
    end

    test "rejects an unrelated string" do
      assert Topics.parse("nonsense") == :error
    end
  end
end
