defmodule AshRemote.Realtime.ClientIdTest do
  @moduledoc """
  R-10 (fix-plan Phase B3-2): `ClientId.register/1` unconditionally
  `:persistent_term.put/2`s a fresh id — every supervisor restart for the same
  base_url triggers a full `:persistent_term` global GC scan (the write cost
  scales with the whole VM's process count) AND changes the echo-correlation
  identity out from under any in-flight requests still carrying the old id.
  Idempotent: register only writes when no id exists yet for that base_url.
  """
  use ExUnit.Case, async: false

  alias AshRemote.Realtime.ClientId

  setup do
    base_url = "http://example.test:#{System.unique_integer([:positive])}"
    on_exit(fn -> ClientId.delete(base_url) end)
    %{base_url: base_url}
  end

  test "register/1 is idempotent — a second call for the same base_url keeps the first id",
       %{base_url: base_url} do
    first = ClientId.register(base_url)
    second = ClientId.register(base_url)

    assert first == second
    assert ClientId.get(base_url) == first
  end
end
