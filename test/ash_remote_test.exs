defmodule AshRemoteTest do
  use ExUnit.Case
  doctest AshRemote

  test "greets the world" do
    assert AshRemote.hello() == :world
  end
end
