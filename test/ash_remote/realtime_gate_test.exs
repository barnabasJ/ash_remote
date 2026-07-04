defmodule AshRemote.RealtimeGateTest do
  @moduledoc """
  Publication gate over the real pub_sub: a `no_publish`'d action broadcasts
  nothing, while an ordinary published action does. (`Comment.create` is exposed
  over RPC but opted out of realtime; `Todo.create` is published.)
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Backend.{Comment, TestBackend, Todo}

  setup do
    TestBackend.reset!()
    Phoenix.PubSub.subscribe(AshRemote.Backend.PubSub, "ash_remote:AshRemote.Backend.Comment")
    Phoenix.PubSub.subscribe(AshRemote.Backend.PubSub, "ash_remote:AshRemote.Backend.Todo")
    :ok
  end

  test "a no_publish'd action broadcasts nothing" do
    Ash.create!(Comment, %{body: "silent"})
    refute_receive %Phoenix.Socket.Broadcast{event: "notification"}, 300
  end

  test "an ordinary published action still broadcasts (control)" do
    Ash.create!(Todo, %{title: "loud", status: :pending})
    assert_receive %Phoenix.Socket.Broadcast{event: "notification", payload: payload}, 1_000
    assert payload["data"]["title"] == "loud"
  end
end
