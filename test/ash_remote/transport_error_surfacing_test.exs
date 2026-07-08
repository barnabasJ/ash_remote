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

  # R0 #9: landed but untested — 401/403 taxonomy. A raw HTTP 401/403 (e.g. a
  # proxy/gateway rejecting the request before it reaches the ash_remote
  # server at all, so there's no typed JSON error body to decode) must
  # normalize to Ash.Error.Forbidden.Policy — the same :auth classification
  # a Forbidden wrapped inside a typed body gets — not fall through to the
  # generic Transport error, which ash_multi_datalayer's LocalOutbox
  # Flush.classify/1 treats as :transient (retry, wrong for an auth
  # failure that won't self-heal by retrying).
  describe "AshRemote.Error.Transport.normalize/1 — 401/403 taxonomy" do
    alias AshRemote.Error.Transport

    test "401 normalizes to Ash.Error.Forbidden.Policy, not the generic Transport error" do
      assert %Ash.Error.Forbidden.Policy{} = Transport.normalize({:http_error, 401, "nope"})
    end

    test "403 normalizes to Ash.Error.Forbidden.Policy, not the generic Transport error" do
      assert %Ash.Error.Forbidden.Policy{} = Transport.normalize({:http_error, 403, "nope"})
    end

    test "other HTTP error statuses (e.g. 500) still become the generic typed Transport error" do
      assert %Transport{status: 500} = Transport.normalize({:http_error, 500, "boom"})
    end

    test "a transport-level failure (connection refused) still becomes a Transport error, unaffected" do
      assert %Transport{status: nil} = Transport.normalize({:transport_error, :econnrefused})
    end
  end
end
