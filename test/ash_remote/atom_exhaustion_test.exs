defmodule AshRemote.AtomExhaustionTest do
  @moduledoc """
  R-2 (fix-plan Phase B0-2 / B1-2): `resolve_resource` on both the RPC path
  (`AshRemote.Server`) and the realtime join path (`AshRemote.Server.Channel`)
  called `Module.concat/1` on the client-supplied resource string BEFORE
  checking membership — every distinct string interned a new atom, reachable
  pre-auth from the wire (an unbounded-cardinality DoS vector).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import Phoenix.ChannelTest

  @endpoint AshRemote.Backend.Endpoint

  defp run_unknown(garbage) do
    AshRemote.Server.run_action(:ash_remote, %{"resource" => garbage, "action" => "read"})
  end

  test "an unknown resource string on /rpc/run never grows the atom table" do
    # Warm-up pass: absorbs any one-time (first-call) atom allocation in the
    # error-handling path itself (unrelated to the bug — e.g. lazily-compiled
    # code touched for the first time) so the MEASURED batch only reflects
    # per-call, per-distinct-string cost.
    for _ <- 1..20, do: run_unknown("AshRemote.NoSuchResource.Warmup#{:erlang.unique_integer()}")

    before_count = :erlang.system_info(:atom_count)

    for _ <- 1..2_000 do
      garbage = "AshRemote.NoSuchResource.Garbage#{System.unique_integer([:positive])}"

      assert %{"success" => false, "errors" => [%{"type" => "unknown_resource"}]} =
               run_unknown(garbage)
    end

    after_count = :erlang.system_info(:atom_count)
    assert after_count - before_count == 0
  end

  defp join_unknown(socket, garbage), do: subscribe_and_join(socket, "ash_remote:" <> garbage, %{})

  test "an unknown resource string on a channel join never grows the atom table" do
    {:ok, socket} = connect(AshRemote.Backend.RemoteSocket, %{"actor_id" => "alice"})

    for _ <- 1..20, do: join_unknown(socket, "AshRemote.NoSuchResource.Warmup#{:erlang.unique_integer()}")

    before_count = :erlang.system_info(:atom_count)

    for _ <- 1..2_000 do
      garbage = "AshRemote.NoSuchResource.Garbage#{System.unique_integer([:positive])}"
      assert {:error, %{reason: "unknown_resource"}} = join_unknown(socket, garbage)
    end

    after_count = :erlang.system_info(:atom_count)
    assert after_count - before_count == 0
  end
end
