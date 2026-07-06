defmodule TodoClient.CacheStats do
  @moduledoc """
  Aggregates `ash_multi_datalayer` telemetry into live counters and pushes
  them to the LiveView over PubSub — the human-visible face of the cache.
  """
  use GenServer

  @topic "cache_stats"
  @events [
    [:ash_multi_datalayer, :read, :hit],
    [:ash_multi_datalayer, :read, :miss],
    [:ash_multi_datalayer, :read, :backfill],
    [:ash_multi_datalayer, :read, :divergence_detected],
    [:ash_multi_datalayer, :ledger, :invalidated]
  ]

  @zero %{hits: 0, misses: 0, backfills: 0, invalidations: 0, divergences: 0}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def topic, do: @topic

  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(nil) do
    :telemetry.attach_many(
      "todo-client-cache-stats",
      @events,
      &__MODULE__.handle_telemetry/4,
      self()
    )

    {:ok, @zero}
  end

  @doc false
  def handle_telemetry([:ash_multi_datalayer, _group, kind], _measurements, _metadata, pid) do
    send(pid, {:telemetry, kind})
  end

  @impl true
  def handle_call(:stats, _from, stats), do: {:reply, stats, stats}

  @impl true
  def handle_info({:telemetry, kind}, stats) do
    key =
      case kind do
        :hit -> :hits
        :miss -> :misses
        :backfill -> :backfills
        :invalidated -> :invalidations
        :divergence_detected -> :divergences
      end

    stats = Map.update!(stats, key, &(&1 + 1))
    Phoenix.PubSub.broadcast(TodoClient.PubSub, @topic, {:cache_stats, stats})
    {:noreply, stats}
  end
end
