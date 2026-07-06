defmodule TodoClient.OfflineLive do
  @moduledoc """
  Offline-sync + conflict-resolution demo over `TodoClient.Local.Todo` (the
  LocalOutbox stack). Reads are served from local SQLite (0 RPC); writes commit
  locally and drain to the server through the Oban-backed outbox.

  Drive it with two instances (see `run_offline.sh`):

    1. Both pages show the same shared (public) todo, hydrated from the server.
    2. Hit **Go offline** on both — `LocalOutbox.pause_sync/1` pauses the flush
       queue; edits now queue locally (red banner).
    3. Edit the same todo differently on each. Bring A online (**Go online**) —
       its update flushes and wins; bring B online — its flush stale-checks,
       finds the server moved, and **parks the entry as a conflict**.
    4. The Conflicts panel shows mine (local) / base / theirs (server)
       field-by-field; resolve with Keep mine (force) / Take theirs (discard
       local) / Retry.

  While online the view auto-refreshes from the server (pulling other clients'
  changes and server-assigned timestamps into clean local rows — dirty rows with
  queued edits are skipped), so the two pages track each other live.
  """
  use Phoenix.LiveView

  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias TodoClient.Local.Todo

  # `version` is the stale-check field (client-authored, see TodoClient.BumpVersion);
  # showing it in the three-way diff makes the conflict cause legible.
  @fields ~w(title completed priority due_date public version updated_at)
  @tick_ms 2500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Instant inbound convergence: RealtimeBridge broadcasts here after the
      # ExternalChange notifier has already refreshed the peer's write into local
      # SQLite. The periodic tick stays as a slower fallback (gap-closing + keeping
      # synced rows' updated_at current), so the page is correct even if a socket
      # notification is missed.
      Phoenix.PubSub.subscribe(TodoClient.PubSub, TodoClient.RealtimeBridge.topic())
      # Our own outbox transitions (pending → synced/parked) — so this client's
      # sync badge settles the instant its flush commits, not on the next poll.
      Phoenix.PubSub.subscribe(TodoClient.PubSub, TodoClient.Sync.OutboxNotifier.topic())
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok,
     socket
     |> assign(user: TodoClient.Session.user(), title: "", public: true, fields: @fields)
     |> load()}
  end

  # A peer's server-side change arrived over the realtime socket; ExternalChange
  # already refreshed local, so just re-read and re-render (push, not poll).
  @impl true
  def handle_info({:remote_change, _resource, _type}, socket) do
    {:noreply, load(socket)}
  end

  # This client's own outbox committed a state change — refresh the sync badges.
  def handle_info(:outbox_changed, socket) do
    {:noreply, load(socket)}
  end

  # Periodic tick: while online, pull the server's clean rows into the local
  # layer (dirty PKs are skipped by refresh), so the page tracks the other
  # instance and keeps synced rows' `updated_at` current. Offline → local only.
  @impl true
  def handle_info(:tick, socket) do
    unless LocalOutbox.sync_paused?(Todo), do: safe_refresh()
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("add", %{"title" => title} = params, socket) do
    title = String.trim(title)

    if title != "" do
      Todo
      |> Ash.Changeset.for_create(:create, %{
        title: title,
        public: params["public"] == "true"
      })
      |> Ash.create!()
    end

    {:noreply, socket |> assign(title: "") |> load()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    todo = Ash.get!(Todo, id)

    todo
    |> Ash.Changeset.for_update(:update, %{completed: not todo.completed})
    |> Ash.update!()

    {:noreply, load(socket)}
  end

  def handle_event("toggle-public", %{"id" => id}, socket) do
    todo = Ash.get!(Todo, id)

    todo
    |> Ash.Changeset.for_update(:update, %{public: not todo.public})
    |> Ash.update!()

    {:noreply, load(socket)}
  end

  def handle_event("rename", %{"todo_id" => id, "title" => title}, socket) do
    title = String.trim(title)

    if title != "" do
      Todo
      |> Ash.get!(id)
      |> Ash.Changeset.for_update(:update, %{title: title})
      |> Ash.update!()
    end

    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Todo |> Ash.get!(id) |> Ash.destroy!()
    {:noreply, load(socket)}
  end

  def handle_event("toggle-offline", _params, socket) do
    if LocalOutbox.sync_paused?(Todo) do
      # Coming online: reconcile BEFORE draining. refresh(:all) closes the gap of
      # changes other clients made while we were offline — the dirty-chain rule
      # skips any PK we edited locally, so catching up never clobbers our queued
      # work. THEN resume the queue: the flush stale-checks each entry against the
      # now-fresh server state, parking a conflict only for rows that truly moved.
      safe_refresh()
      LocalOutbox.resume_sync(Todo)
    else
      LocalOutbox.pause_sync(Todo)
    end

    {:noreply, load(socket)}
  end

  def handle_event("refresh", _params, socket) do
    safe_refresh()
    {:noreply, load(socket)}
  end

  # --- conflict resolution ----------------------------------------------

  def handle_event("resolve", %{"seq" => seq, "verb" => verb}, socket) do
    seq = String.to_integer(seq)

    case Enum.find(socket.assigns.parked, &(&1.seq == seq)) do
      nil ->
        :ok

      entry ->
        case verb do
          "force" -> LocalOutbox.force(entry)
          "discard_local" -> LocalOutbox.discard_local(entry)
          "retry" -> LocalOutbox.retry(entry)
          "discard" -> LocalOutbox.discard(entry)
        end
    end

    {:noreply, load(socket)}
  end

  # --- data --------------------------------------------------------------

  defp load(socket) do
    todos = Todo |> Ash.Query.sort(:title) |> Ash.read!()
    pending = LocalOutbox.pending(Todo)
    parked = LocalOutbox.parked(Todo)

    assign(socket,
      todos: todos,
      pending: pending,
      parked: parked,
      conflicts: Enum.filter(parked, &(&1.error_class == :conflict)),
      paused?: LocalOutbox.sync_paused?(Todo),
      status_by_id: Map.new(todos, &{&1.id, LocalOutbox.status(&1)})
    )
  end

  defp safe_refresh do
    LocalOutbox.refresh(Todo, :all)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # --- render ------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: 46rem; margin: 0 auto 3rem; font-family: system-ui, sans-serif;">
      <header style="display:flex; align-items:baseline; gap:.75rem; margin:1.5rem .5rem;">
        <h1 style="margin:0;">Offline Todos</h1>
        <small style="color:#888;">
          {@user && @user["email"]} · LocalOutbox (SQLite authority + outbox)
        </small>
        <a href="/" style="margin-left:auto; font-size:.85rem;">← online demo</a>
      </header>

      <div :if={@paused?} style="margin:0 .5rem 1rem; padding:.6rem .9rem; background:#c0392b; color:#fff; border-radius:.4rem; font-weight:600;">
        OFFLINE — changes are queued locally and will flush when you go online.
      </div>

      <div style="display:flex; gap:.75rem; align-items:center; margin:0 .5rem 1rem; flex-wrap:wrap;">
        <button
          phx-click="toggle-offline"
          style={"padding:.5rem 1rem; border-radius:.4rem; border:1px solid #999; cursor:pointer; font-weight:600; " <>
            if(@paused?, do: "background:#c0392b; color:#fff;", else: "background:#e6f7e6;")}
        >
          {if @paused?, do: "Go online", else: "Go offline"}
        </button>

        <button phx-click="refresh" style="padding:.5rem 1rem; border-radius:.4rem; border:1px solid #ccc; cursor:pointer;">
          Refresh from server
        </button>

        <span style="font-size:.85rem; color:#555;">
          sync:
          <b style={pending_color(@pending)}>{length(@pending)}</b> pending ·
          <b style={parked_color(@parked)}>{length(@parked)}</b> parked ·
          <b>{synced_count(@status_by_id)}</b> synced
        </span>
      </div>

      <div :if={@conflicts != []} style="margin:0 .5rem 1.5rem; border:2px solid #c0392b; border-radius:.5rem; overflow:hidden;">
        <div style="background:#c0392b; color:#fff; padding:.5rem .9rem; font-weight:600;">
          Conflicts ({length(@conflicts)}) — the server row changed under you
        </div>
        <div :for={entry <- @conflicts} style="padding:.9rem; border-top:1px solid #eee;">
          <div style="font-size:.8rem; color:#888; margin-bottom:.5rem;">
            {entry.op} · row {short_pk(entry.record_pk)} · entry #{entry.seq}
          </div>
          <div style="overflow-x:auto;">
            <table style="border-collapse:collapse; width:100%; font-size:.82rem;">
              <thead>
                <tr>
                  <th style={th()}>field</th>
                  <th style={th()}>mine (local)</th>
                  <th style={th()}>base</th>
                  <th style={th()}>server (theirs)</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={field <- @fields} :if={row_relevant?(entry, field)}>
                  <td style={td_key()}>{field}</td>
                  <td style={td(diff?(entry.payload, entry.remote_snapshot, field))}>
                    {fmt(field_value(entry.payload, field))}
                  </td>
                  <td style={td(false)}>{fmt(field_value(entry.base_image, field))}</td>
                  <td style={td(diff?(entry.payload, entry.remote_snapshot, field))}>
                    {fmt(field_value(entry.remote_snapshot, field))}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <div style="display:flex; gap:.5rem; margin-top:.7rem; flex-wrap:wrap;">
            <button phx-click="resolve" phx-value-seq={entry.seq} phx-value-verb="force" style={btn("#2e7d32")}>
              Keep mine (force)
            </button>
            <button phx-click="resolve" phx-value-seq={entry.seq} phx-value-verb="discard_local" style={btn("#c62828")}>
              Take theirs (discard local)
            </button>
            <button phx-click="resolve" phx-value-seq={entry.seq} phx-value-verb="retry" style={btn("#555")}>
              Retry
            </button>
          </div>
        </div>
      </div>

      <form phx-submit="add" style="display:flex; gap:.5rem; margin:0 .5rem 1.5rem;">
        <input name="title" value={@title} placeholder="New todo…" style="flex:1; padding:.45rem;" />
        <label style="display:flex; align-items:center; gap:.25rem; font-size:.85rem;">
          <input type="checkbox" name="public" value="true" checked={@public} /> public
        </label>
        <button style="padding:.45rem .9rem;">Add</button>
      </form>

      <ul style="list-style:none; padding:0; margin:0 .5rem;">
        <li :for={todo <- @todos} style="display:flex; align-items:center; gap:.5rem; padding:.45rem 0; border-bottom:1px solid #eee;">
          <input type="checkbox" checked={todo.completed} phx-click="toggle" phx-value-id={todo.id} />
          <form phx-submit="rename" style="flex:1; display:flex; gap:.4rem;">
            <input type="hidden" name="todo_id" value={todo.id} />
            <input
              name="title"
              value={todo.title}
              id={"title-#{todo.id}-#{:erlang.phash2(todo.title)}"}
              style={"flex:1; padding:.3rem; border:1px solid #eee; " <>
                if(todo.completed, do: "color:#999; text-decoration:line-through;", else: "")}
            />
          </form>
          <button
            phx-click="toggle-public"
            phx-value-id={todo.id}
            title={if todo.public, do: "Public — replicates to every client. Click to make private.", else: "Private — owner-only, never leaves this client. Click to make public."}
            style={"border:1px solid #ddd; border-radius:.5rem; padding:.1rem .45rem; cursor:pointer; font-size:.7rem; white-space:nowrap; " <>
              if(todo.public, do: "background:#e7f0ff; color:#1a56c4;", else: "background:#f2f2f2; color:#777;")}
          >
            {if todo.public, do: "🌐 public", else: "🔒 private"}
          </button>
          <span style="font-size:.7rem;">{status_badge(Map.get(@status_by_id, todo.id))}</span>
          <button phx-click="delete" phx-value-id={todo.id} style="border:0; background:none; cursor:pointer; color:#c00;">✕</button>
        </li>
      </ul>
      <p :if={@todos == []} style="color:#888; margin:1rem .5rem;">no todos yet — add one, or refresh from the server</p>
    </div>
    """
  end

  # --- view helpers ------------------------------------------------------

  defp status_badge(:synced), do: badge("synced", "#2e7d32", "#e6f7e6")
  defp status_badge(:pending), do: badge("pending", "#8a6d00", "#fff6d6")
  defp status_badge({:parked, _}), do: badge("parked", "#c62828", "#fbeaea")
  defp status_badge(_), do: ""

  defp badge(text, color, bg) do
    assigns = %{text: text, color: color, bg: bg}

    ~H"""
    <span style={"background:#{@bg}; color:#{@color}; padding:.1rem .45rem; border-radius:.5rem;"}>{@text}</span>
    """
  end

  defp synced_count(status_by_id),
    do: status_by_id |> Map.values() |> Enum.count(&(&1 == :synced))

  defp pending_color([]), do: "color:#2e7d32;"
  defp pending_color(_), do: "color:#8a6d00;"
  defp parked_color([]), do: "color:#2e7d32;"
  defp parked_color(_), do: "color:#c62828;"

  # `remote_snapshot == nil` means the server row is gone (a delete-vs-edit
  # conflict); only render fields present on either side otherwise.
  defp row_relevant?(_entry, _field), do: true

  defp field_value(nil, _field), do: :__absent__
  defp field_value(map, field) when is_map(map), do: Map.get(map, field, :__absent__)

  defp diff?(mine, theirs, field) do
    m = field_value(mine, field)
    t = field_value(theirs, field)
    m != t
  end

  defp fmt(:__absent__), do: "—"
  defp fmt(nil), do: "∅"
  defp fmt(true), do: "true"
  defp fmt(false), do: "false"
  defp fmt(v) when is_binary(v), do: v
  defp fmt(v), do: inspect(v)

  defp short_pk(%{"id" => id}), do: String.slice(id, 0, 8)
  defp short_pk(pk), do: inspect(pk)

  defp th,
    do:
      "text-align:left; padding:.3rem .5rem; border-bottom:1px solid #ddd; background:#fafafa; font-weight:600;"

  defp td_key,
    do: "padding:.3rem .5rem; border-bottom:1px solid #f0f0f0; color:#888; font-weight:600;"

  defp td(true),
    do: "padding:.3rem .5rem; border-bottom:1px solid #f0f0f0; background:#fff6d6;"

  defp td(false), do: "padding:.3rem .5rem; border-bottom:1px solid #f0f0f0;"

  defp btn(color),
    do:
      "padding:.4rem .8rem; border:0; border-radius:.4rem; cursor:pointer; color:#fff; background:#{color};"
end
