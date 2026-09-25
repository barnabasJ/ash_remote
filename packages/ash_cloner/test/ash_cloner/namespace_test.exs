defmodule AshCloner.NamespaceTest do
  use ExUnit.Case, async: true

  alias AshCloner.Namespace

  doctest AshCloner.Namespace

  describe "common_prefix/1" do
    test "empty list has no prefix" do
      assert Namespace.common_prefix([]) == []
    end

    test "finds the shared leading segments" do
      assert Namespace.common_prefix(["MyLib.Blog.Post", "MyLib.Blog.Comment"]) ==
               ["MyLib", "Blog"]
    end

    test "stops at the first divergence" do
      assert Namespace.common_prefix(["MyLib.Blog.Post", "MyLib.Accounts.User"]) == ["MyLib"]
    end

    test "never consumes the final segment of the shortest module" do
      # "MyLib.Blog" is fully contained in the prefix of the other — keep its leaf.
      assert Namespace.common_prefix(["MyLib.Blog", "MyLib.Blog.Post"]) == ["MyLib"]
    end

    test "a single module keeps its leaf" do
      assert Namespace.common_prefix(["MyLib.Blog.Post"]) == ["MyLib", "Blog"]
    end
  end

  describe "reprefix/3" do
    test "swaps the prefix for the namespace" do
      assert Namespace.reprefix("MyLib.Blog.Post", ["MyLib", "Blog"], "UserApp.Content") ==
               "UserApp.Content.Post"
    end

    test "an empty prefix nests the whole module under the namespace" do
      assert Namespace.reprefix("Post", [], "UserApp") == "UserApp.Post"
    end
  end
end
