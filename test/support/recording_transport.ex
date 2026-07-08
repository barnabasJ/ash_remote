defmodule AshRemote.Test.RecordingTransport do
  @moduledoc """
  A transport wrapper that records every `%Config{}`/`body` pair it is
  called with (headers, retry policy, the wire action name), then delegates
  to the real `AshRemote.Transport.Req` — used by the L7-1 (header dedupe)
  and L7-2 (write-retry scoping) regressions to observe what the data layer
  actually handed the transport, not just the end-to-end HTTP outcome.
  """
  @behaviour AshRemote.Transport

  @table :ash_remote_recording_transport

  def ensure_table! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :bag])
    end

    :ok
  end

  def reset!, do: :ets.delete_all_objects(@table)

  @doc "All recorded calls, oldest first: `%{action:, headers:, retry:}`."
  def calls do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_ref, call} -> call end)
    |> Enum.sort_by(& &1.seq)
  end

  @impl true
  def request(config, path, body) do
    :ets.insert(
      @table,
      {make_ref(),
       %{
         seq: System.unique_integer([:monotonic]),
         action: body["action"],
         headers: config.headers,
         retry: config.retry
       }}
    )

    AshRemote.Transport.Req.request(config, path, body)
  end
end
