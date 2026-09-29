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
    [:ash_multi_datalayer, :read, :partial],
    [:ash_multi_datalayer, :read, :backfill],
    [:ash_multi_datalayer, :read, :divergence_detected],
    [:ash_multi_datalayer, :ledger, :invalidated],
    [:ash_multi_datalayer, :ledger, :evicted]
  ]

  @zero %{
    hits: 0,
    misses: 0,
    partials: 0,
    backfills: 0,
    invalidations: 0,
    evictions: 0,
    divergences: 0,
    recent_reads: []
  }
  @recent_limit 30

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def topic, do: @topic

  def stats, do: GenServer.call(__MODULE__, :stats)

  def row_label(%TodoClient.Remote.Todo{title: title}), do: title
  def row_label(%TodoClient.Remote.TodoList{name: name}), do: name
  def row_label(_record), do: nil

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
  def handle_telemetry([:ash_multi_datalayer, _group, kind], measurements, metadata, pid) do
    send(pid, {:telemetry, kind, measurements, metadata})
  end

  @impl true
  def handle_call(:stats, _from, stats), do: {:reply, stats, stats}

  @impl true
  def handle_info({:telemetry, kind, measurements, metadata}, stats) do
    key =
      case kind do
        :hit -> :hits
        :miss -> :misses
        :partial -> :partials
        :backfill -> :backfills
        :invalidated -> :invalidations
        :evicted -> :evictions
        :divergence_detected -> :divergences
      end

    stats = Map.update!(stats, key, &(&1 + 1))

    stats =
      if kind in [:hit, :miss, :partial] do
        read = %{
          id: System.unique_integer([:positive, :monotonic]),
          kind: kind,
          resource: metadata.resource |> Module.split() |> List.last(),
          duration_us: measurements[:duration_us],
          cached: metadata[:cached],
          fetched: metadata[:fetched],
          cached_labels: metadata[:cached_labels] || [],
          fetched_labels: metadata[:fetched_labels] || [],
          reason: metadata[:reason],
          fingerprint: metadata[:filter_fingerprint],
          at: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")
        }

        Map.update!(stats, :recent_reads, &Enum.take([read | &1], @recent_limit))
      else
        stats
      end

    Phoenix.PubSub.broadcast(TodoClient.PubSub, @topic, {:cache_stats, stats})
    {:noreply, stats}
  end
end
