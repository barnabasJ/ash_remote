defmodule TodoClient.LedgerLive do
  @moduledoc """
  Read-only view of this client's ProvenCoverage ledger. It reads the local ETS
  index directly, so opening the page does not warm the cache or make an RPC.
  """
  use Phoenix.LiveView

  alias AshMultiDatalayer.Debug

  @resources [
    {"Todos", TodoClient.Remote.Todo},
    {"Todo lists", TodoClient.Remote.TodoList}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TodoClient.PubSub, TodoClient.CacheStats.topic())
    end

    {:ok, socket |> assign(open_entries: MapSet.new()) |> refresh()}
  end

  @impl true
  def handle_info({:cache_stats, _stats}, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("toggle-entry", %{"key" => key}, socket) do
    open_entries = socket.assigns.open_entries

    open_entries =
      if MapSet.member?(open_entries, key),
        do: MapSet.delete(open_entries, key),
        else: MapSet.put(open_entries, key)

    {:noreply, assign(socket, open_entries: open_entries)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main style="max-width: 65rem; margin: 2rem auto 4rem; padding: 0 1rem; font-family: system-ui, sans-serif; color: #243041;">
      <header style="display:flex; justify-content:space-between; align-items:start; gap:1rem; flex-wrap:wrap;">
        <div>
          <h1 style="margin:0 0 .35rem;">Coverage ledger</h1>
          <p style="margin:.25rem 0; color:#526173;">
            The filters this client has fully loaded into its online ETS cache.
          </p>
        </div>
        <button phx-click="refresh" style="padding:.45rem .8rem; border:1px solid #aebbc9; border-radius:.4rem; background:white; cursor:pointer;">
          Refresh now
        </button>
      </header>

      <div style="display:flex; gap:1rem; flex-wrap:wrap; margin:1.5rem 0;">
        <div style="padding:.8rem 1rem; background:#edf4ff; border-radius:.5rem; min-width:10rem;">
          <strong style="font-size:1.5rem;">{@total}</strong><br />
          <span>coverage entries</span>
        </div>
        <div style="padding:.8rem 1rem; background:#f3f5f7; border-radius:.5rem;">
          <strong>ProvenCoverage</strong><br />
          <span>node-local, in-memory ledger · updates when cache coverage changes</span>
        </div>
      </div>

      <p style="line-height:1.5; color:#526173;">
        An entry means that the full result of its filter, with the listed fields, is in this
        client's cache. A narrower read can use that coverage. A row change narrows the
        affected filter around that ID; the next successful read fills the hole in the
        same entry. Restarting this client clears the ledger.
      </p>

      <section style="margin:2rem 0;">
        <h2 style="border-bottom:2px solid #dce4ed; padding-bottom:.4rem;">How reads were served</h2>
        <p style="color:#526173; line-height:1.5;">
          Each read checks the ledger. A covered query uses the cache; an overlapping query
          checks the covered region and requests only the uncovered filter from the server. A miss
          reads the whole query from the server. These counts are for this client process since
          it started; refreshing this browser page does not reset them.
          After a remote change, Grace evicts the old row; a server read can refill ETS, so the
          next read can be a cache hit for the new value.
        </p>
        <div style="display:flex; gap:.7rem; flex-wrap:wrap; margin:1rem 0;">
          <div style="padding:.7rem 1rem; border-radius:.5rem; background:#e8f5ee;"><strong>{@stats.hits}</strong> cache hits</div>
          <div style="padding:.7rem 1rem; border-radius:.5rem; background:#e8f0fc;"><strong>{@stats.partials}</strong> filter splits</div>
          <div style="padding:.7rem 1rem; border-radius:.5rem; background:#fff2e7;"><strong>{@stats.misses}</strong> full remote reads</div>
          <div style="padding:.7rem 1rem; border-radius:.5rem; background:#f3f5f7;"><strong>{@stats.backfills}</strong> backfills</div>
          <div style="padding:.7rem 1rem; border-radius:.5rem; background:#f3f5f7;"><strong>{@stats.invalidations}</strong> invalidations</div>
        </div>
        <h3 style="margin:1.4rem 0 .5rem;">Recent query decisions (history)</h3>
        <p :if={@stats.recent_reads == []} style="color:#657386;">No reads observed yet. Use the Online page to make a query.</p>
        <ol style="list-style:none; padding:0; margin:0; display:grid; gap:.6rem;">
          <li :for={read <- @stats.recent_reads} style="border:1px solid #dce4ed; border-radius:.5rem; padding:.75rem 1rem; background:white;">
            <div style="display:flex; justify-content:space-between; gap:.75rem; flex-wrap:wrap;">
              <strong>{read.resource} · {read_label(read)}</strong>
              <small style="color:#657386;">{read.at} · {format_duration(read.duration_us)}</small>
            </div>
            <div style="display:flex; align-items:center; gap:.35rem; flex-wrap:wrap; margin-top:.5rem; font-size:.85rem;">
              <span style="padding:.25rem .5rem; border-radius:.3rem; background:#e8f5ee;">Cache {cache_detail(read)}</span>
              <span style="color:#657386;">→</span>
              <span style="padding:.25rem .5rem; border-radius:.3rem; background:#fff2e7;">Server {server_detail(read)}</span>
              <span style="color:#657386;">→ result</span>
            </div>
            <div :if={read.cached_labels != []} style="margin-top:.45rem; font-size:.85rem; color:#315d48;">From cache: {Enum.join(read.cached_labels, ", ")}</div>
            <div :if={read.fetched_labels != []} style="margin-top:.25rem; font-size:.85rem; color:#81502a;">From server: {Enum.join(read.fetched_labels, ", ")}</div>
            <small :if={read.kind == :partial and read.cached == 0} style="display:block; margin-top:.45rem; color:#657386;">The filter was partitioned, but the covered region returned no rows.</small>
            <small :if={read.reason} style="display:block; margin-top:.45rem; color:#657386;">Reason: {read.reason}</small>
            <small :if={read.fingerprint} style="display:block; margin-top:.2rem; color:#657386;">Filter shape {read.fingerprint} · values omitted from telemetry</small>
          </li>
        </ol>
        <p style="font-size:.82rem; color:#657386;">
          These are past reads, not the current source of a todo. The last 30 decisions are kept
          in this client process across browser refreshes. Split reads include row counts;
          hits and misses report the path and duration. Up to 50 row names are shown per path
          for this local demo.
        </p>
      </section>

      <section :for={resource <- @resources} style="margin-top:2rem;">
        <h2 style="display:flex; align-items:baseline; gap:.7rem; border-bottom:2px solid #dce4ed; padding-bottom:.4rem;">
          {resource.label}
          <small style="font-weight:normal; color:#657386;">{length(resource.entries)} entries</small>
        </h2>
        <p :if={resource.entries == []} style="padding:.8rem 1rem; background:#f7f9fb; color:#657386; border-radius:.4rem;">
          No coverage yet. Visit the Online page and use a Browse filter to fill it.
        </p>
        <div :for={entry <- resource.entries} style="border:1px solid #dce4ed; border-radius:.55rem; padding:.9rem 1rem; margin:.7rem 0; background:white;">
          <div style="display:flex; align-items:baseline; justify-content:space-between; gap:.75rem; flex-wrap:wrap;">
            <strong>Filter</strong>
            <small style="color:#657386;">last used {entry.last_used}</small>
          </div>
          <pre style="white-space:pre-wrap; overflow-wrap:anywhere; background:#f7f9fb; padding:.7rem; border-radius:.35rem; font-size:.82rem;">{entry.filter}</pre>
          <button
            type="button"
            phx-click="toggle-entry"
            phx-value-key={entry.key}
            aria-expanded={MapSet.member?(@open_entries, entry.key)}
            style="border:0; padding:0; background:none; cursor:pointer; color:#315d98; font:inherit;"
          >
            {if MapSet.member?(@open_entries, entry.key), do: "▾", else: "▸"} How coverage is stored
          </button>
          <div :if={MapSet.member?(@open_entries, entry.key)}>
            <p style="font-size:.85rem;"><strong>Loaded fields:</strong> {entry.fields}</p>
            <p style="font-size:.85rem;"><strong>Normalized intervals:</strong></p>
            <pre style="white-space:pre-wrap; overflow-wrap:anywhere; background:#f7f9fb; padding:.7rem; border-radius:.35rem; font-size:.82rem;">{entry.normalised}</pre>
          </div>
        </div>
      </section>

      <aside style="margin-top:2rem; padding:1rem; border-left:4px solid #7856a6; background:#f7f2fc; line-height:1.5;">
        <strong>Offline page: LocalOutbox</strong><br />
        It has no coverage ledger. Its SQLite layer is the complete local authority, so reads
        do not need a coverage proof. Pending writes live in a durable outbox; see
        <a href="/oban">Oban Web</a> for its flush jobs.
      </aside>
    </main>
    """
  end

  defp refresh(socket) do
    now = System.monotonic_time()

    resources =
      Enum.map(@resources, fn {label, module} ->
        entries =
          module
          |> Debug.dump_ledger()
          |> Enum.sort_by(& &1.loaded_at, :desc)
          |> Enum.map(&present_entry(&1, now))

        %{label: label, entries: entries}
      end)

    current_keys =
      resources
      |> Enum.flat_map(fn resource -> Enum.map(resource.entries, & &1.key) end)
      |> MapSet.new()

    assign(socket,
      resources: resources,
      total: Enum.sum(Enum.map(resources, &length(&1.entries))),
      stats: TodoClient.CacheStats.stats(),
      open_entries: MapSet.intersection(socket.assigns.open_entries, current_keys)
    )
  end

  defp read_label(%{kind: :hit}), do: "cache hit"
  defp read_label(%{kind: :partial, cached: 0}), do: "remote remainder (0 cached)"
  defp read_label(%{kind: :partial}), do: "cache + remote"
  defp read_label(%{kind: :miss}), do: "remote read"

  defp cache_detail(%{kind: :hit}), do: "covered"
  defp cache_detail(%{kind: :partial, cached: count}), do: "#{count} rows"
  defp cache_detail(_read), do: "not used"

  defp server_detail(%{kind: :hit}), do: "not used"
  defp server_detail(%{kind: :partial, fetched: count}), do: "#{count} rows"
  defp server_detail(_read), do: "full query"

  defp format_duration(nil), do: "duration unavailable"
  defp format_duration(us) when us < 1_000, do: "#{us} µs"
  defp format_duration(us), do: "#{Float.round(us / 1_000, 1)} ms"

  defp present_entry(entry, now) do
    elapsed = max(now - entry.loaded_at, 0)
    seconds = System.convert_time_unit(elapsed, :native, :second)

    %{
      key: entry.id |> :erlang.term_to_binary() |> Base.url_encode64(padding: false),
      filter:
        if(entry.filter,
          do: inspect(entry.filter, pretty: true, limit: 40),
          else: "all rows"
        ),
      fields: entry.loaded_fields |> MapSet.to_list() |> Enum.sort() |> Enum.join(", "),
      normalised: inspect(entry.normalised.disjuncts, pretty: true, limit: 40),
      last_used: "#{seconds}s ago"
    }
  end
end
