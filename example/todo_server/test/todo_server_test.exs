defmodule TodoServerTest do
  use ExUnit.Case
  doctest TodoServer

  test "greets the world" do
    assert TodoServer.hello() == :world
  end
end
