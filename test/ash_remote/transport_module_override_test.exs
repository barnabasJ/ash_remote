defmodule AshRemote.TransportModuleOverrideTest do
  @moduledoc """
  Regression: a `remote do ... end`-DSL-declared (i.e. generated, per `mix
  ash_remote.gen`) resource's config never carries a `:transport` key at all
  (`DataLayer.remote_config/1`'s generated-resource branch only returns
  `%{source:, base_url:, action_map:}`) — only the older, hand-authored
  `Application.get_env(:ash_remote, :remote_config)` resource style could ever
  set a custom transport directly on its own config map. This meant a
  generated resource had NO seam at all to swap in a fake/mocked transport
  under test — the exact seam the `mob/` project's Mox-based testing strategy
  needs (`AshRemote.Transport` is a `@behaviour`, the natural `Mox.defmock`
  target). Fixed with a global `config :ash_remote, :transport_module`
  fallback every resource's default `Transport.Config.new/1` now picks up,
  mirroring the existing `:base_url` app-env fallback.
  """
  use ExUnit.Case, async: false

  alias AshRemote.RealtimeClient.Todo, as: ClientTodo

  defmodule FakeTransport do
    @moduledoc false
    @behaviour AshRemote.Transport

    @impl true
    def request(_config, :run, _body) do
      {:ok,
       %{
         "success" => true,
         "data" => [
           %{
             "id" => "11111111-1111-1111-1111-111111111111",
             "title" => "from the fake transport",
             "completed" => false
           }
         ]
       }}
    end

    def request(_config, _path, _body), do: {:error, :unexpected_request}
  end

  setup do
    # An unreachable base_url proves the real transport was never attempted —
    # if the override weren't honored, this read would fail/timeout instead
    # of returning the fake's canned response.
    Application.put_env(:ash_remote, :base_url, "http://127.0.0.1:1")
    Application.put_env(:ash_remote, :transport_module, FakeTransport)

    on_exit(fn ->
      Application.delete_env(:ash_remote, :base_url)
      Application.delete_env(:ash_remote, :transport_module)
    end)
  end

  test "a generated (remote do end-declared) resource honors :transport_module" do
    assert {:ok, [todo]} = Ash.read(ClientTodo)
    assert todo.title == "from the fake transport"
  end
end
