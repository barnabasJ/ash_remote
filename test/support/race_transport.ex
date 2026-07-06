defmodule AshRemote.Test.RaceTransport do
  @moduledoc """
  A transport wrapper that can park the NEXT `read`-shaped `/rpc/run` request
  after capturing its real response — for deterministically reproducing the
  R-7 `upsert/3` create-collision race without sleeps. Mirrors
  `ash_multi_datalayer`'s `BlockingLayer` test-support pattern: the park
  happens AFTER delegating, so the caller resumes with the STALE (pre-park)
  response even though state changed while it was parked.
  """
  @behaviour AshRemote.Transport

  @table :ash_remote_race_transport

  def ensure_table! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc "Arms the transport to park the next `read`-action request reached."
  def arm, do: :ets.insert(@table, {:armed, self()})

  @doc "Releases a parked request, identified by the pid from the parked notification."
  def release(pid), do: send(pid, {:race_transport_release, self()})

  @impl true
  def request(config, path, body) do
    result = AshRemote.Transport.Req.request(config, path, body)

    if path == :run and body["action"] == "read" do
      case :ets.take(@table, :armed) do
        [{:armed, test_pid}] ->
          send(test_pid, {:race_transport_parked, self()})

          receive do
            {:race_transport_release, _} -> :ok
          end

        [] ->
          :ok
      end
    end

    result
  end
end
