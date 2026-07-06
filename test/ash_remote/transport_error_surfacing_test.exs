defmodule AshRemote.TransportErrorSurfacingTest do
  @moduledoc """
  R-6 (fix-plan Phase B0-4 / B2-1): a transport failure (backend unreachable)
  must surface as a typed `Ash.Error`, not a raw `{:transport_error, reason}}`
  tuple — the shape retry/circuit-breaker logic (and ash_multi_datalayer's
  LocalOutbox `Flush.classify/1`) needs a stable type to match on.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Client.Todo

  setup do
    Application.put_env(:ash_remote, :remote_config, %{
      Todo => %{base_url: "http://127.0.0.1:1", source: "AshRemote.Backend.Todo"}
    })

    on_exit(fn -> Application.delete_env(:ash_remote, :remote_config) end)
    :ok
  end

  test "a read against an unreachable backend surfaces a typed Ash.Error" do
    assert {:error, error} = Ash.read(Todo)
    assert %Ash.Error.Unknown{} = error
    refute match?(%Ash.Error.Unknown{errors: [{:transport_error, _} | _]}, error)
    assert Enum.any?(error.errors, &match?(%AshRemote.Error.Transport{}, &1))
  end

  test "a create against an unreachable backend surfaces a typed Ash.Error" do
    assert {:error, error} = Ash.create(Todo, %{title: "x"})
    assert %Ash.Error.Unknown{} = error
    assert Enum.any?(error.errors, &match?(%AshRemote.Error.Transport{}, &1))
  end
end
