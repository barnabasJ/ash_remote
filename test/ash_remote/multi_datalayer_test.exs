defmodule AshRemote.MultiDatalayerTest do
  use ExUnit.Case, async: true

  alias AshRemote.MultiDatalayer
  alias AshRemote.MultiDatalayer.ChangeNotifier
  alias AshRemote.Test.MultiDatalayer.Resources.{CachedThing, PlainEtsThing}

  describe "ordered?/1" do
    test "true when the change notifier is first (its only notifier here)" do
      assert MultiDatalayer.ordered?(CachedThing)
    end

    test "false for a resource with no notifiers at all" do
      refute MultiDatalayer.ordered?(PlainEtsThing)
    end

    test "false (not raising) for a non-resource module" do
      refute MultiDatalayer.ordered?(NotARealResourceModule)
    end
  end

  describe "notifiers/1" do
    test "prepends the change notifier" do
      assert MultiDatalayer.notifiers([Foo, Bar]) == [ChangeNotifier, Foo, Bar]
    end

    test "defaults to just the change notifier" do
      assert MultiDatalayer.notifiers() == [ChangeNotifier]
    end

    test "wraps a bare module" do
      assert MultiDatalayer.notifiers(Foo) == [ChangeNotifier, Foo]
    end
  end
end
