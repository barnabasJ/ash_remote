defmodule TodoClient.OfflineLive do
  @moduledoc """
  Offline-sync + conflict-resolution demo over `TodoClient.Local.Todo` (the
  LocalOutbox stack). Reads are served from local SQLite (0 RPC); writes commit
  locally and drain to the server through the Oban-backed outbox.

  Drive it with two instances (see `../run.sh`):

    1. Both pages show the same shared (public) todo, hydrated from the server.
    2. Hit **Go offline** on both — `LocalOutbox.pause_sync/1` pauses the flush
       queue; edits now queue locally (red banner).
    3. Edit the same todo differently on each. Bring A online (**Go online**) —
       its update flushes and wins; bring B online — the server rejects its
       old base version, and the outbox **parks the entry as a conflict**.
    4. The Conflicts panel shows mine (local) / base / theirs (server)
       field-by-field; resolve with Keep mine (force) / Take theirs (discard
       local) / Retry.

  While online the view auto-refreshes from the server (pulling other clients'
  changes and server-assigned timestamps into clean local rows — dirty rows with
  queued edits are skipped), so the two pages track each other live.
  """
  use Phoenix.LiveView
  import TodoClient.Components

  alias AshMultiDatalayer.Orchestrator.LocalOutbox
  alias TodoClient.Local.Todo
  alias TodoClient.Local.TodoList

  # `version` is the conflict field (client-authored, see TodoClient.BumpVersion);
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
     |> assign(user: TodoClient.Session.user(), todo_params: %{}, fields: @fields)
     |> load()}
  end

  # A peer's server-side change arrived over the realtime socket; ExternalChange
  # already refreshed local, so just re-read and re-render (push, not poll).
  @impl true
  def handle_info({:remote_change, resource, _type, _id}, socket)
      when resource in [Todo, TodoList] do
    {:noreply, load(socket)}
  end

  def handle_info({:remote_change, resource, _type, _id, _record}, socket)
      when resource in [Todo, TodoList] do
    {:noreply, load(socket)}
  end

  def handle_info({:remote_change, _resource, _type, _id}, socket), do: {:noreply, socket}

  def handle_info({:remote_change, _resource, _type, _id, _record}, socket),
    do: {:noreply, socket}

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
  def handle_event("validate", %{"todo" => params}, socket) do
    {:noreply, assign(socket, todo_params: params)}
  end

  def handle_event("save", %{"todo" => params}, socket) do
    attrs = %{
      title: String.trim(params["title"] || ""),
      public: params["public"] == "true",
      list_id: blank_to_nil(params["list_id"])
    }

    result = Todo |> Ash.Changeset.for_create(:create, attrs) |> Ash.create()

    case result do
      {:ok, _todo} ->
        {:noreply, socket |> clear_flash(:error) |> assign(todo_params: %{}) |> load()}

      {:error, _error} ->
        {:noreply,
         socket
         |> assign(todo_params: params)
         |> put_flash(:error, "Could not create that todo. Check its title and try again.")}
    end
  end

  def handle_event("add_list", params, socket) do
    attrs = %{name: String.trim(params["name"] || ""), public: params["public"] == "true"}

    case TodoList |> Ash.Changeset.for_create(:create, attrs) |> Ash.create() do
      {:ok, _list} ->
        {:noreply, socket |> clear_flash(:error) |> load()}

      {:error, _error} ->
        {:noreply,
         put_flash(socket, :error, "Could not create that list. Check its name and try again.")}
    end
  end

  def handle_event("dismiss-flash", %{"kind" => kind}, socket) when kind in ["info", "error"] do
    {:noreply, clear_flash(socket, String.to_existing_atom(kind))}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    todo = Ash.get!(Todo, id)

    todo
    |> Ash.Changeset.for_update(:update, %{completed: not todo.completed})
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
      # work. THEN resume the queue: each queued write carries its base version,
      # and the server rejects stale updates/deletes for the outbox to park.
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
    lists = TodoList |> Ash.Query.sort(:name) |> Ash.read!()
    pending = Enum.flat_map([TodoList, Todo], &LocalOutbox.pending/1)
    parked = Enum.flat_map([TodoList, Todo], &LocalOutbox.parked/1)

    lists =
      Enum.map(lists, fn list ->
        list_todos = Enum.filter(todos, &(&1.list_id == list.id))

        list
        |> Map.put(:todos, list_todos)
        |> Map.put(:todo_count, length(list_todos))
        |> Map.put(:completed_count, Enum.count(list_todos, & &1.completed))
      end)

    assign(socket,
      todos: todos,
      lists: lists,
      pending: pending,
      parked: parked,
      conflicts: Enum.filter(parked, &(&1.error_class == :conflict)),
      paused?: LocalOutbox.sync_paused?(Todo),
      status_by_id: Map.new(todos, &{&1.id, LocalOutbox.status(&1)})
    )
  end

  defp safe_refresh do
    for resource <- [TodoList, Todo], do: LocalOutbox.refresh(resource, :all)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # --- render ------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="demo-page">
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

      <.notices flash={@flash} />

      <section class="panel">
        <h2>Create a list</h2>
        <.list_form />
      </section>

      <section class="panel">
        <h2>Add a todo</h2>
        <.todo_form
          lists={@lists}
          title={Map.get(@todo_params, "title", "")}
          list_id={Map.get(@todo_params, "list_id")}
          public={Map.get(@todo_params, "public") == "true"}
          allow_unlisted={true}
        />
      </section>

      <.list_section :for={list <- @lists} list={list}>
        <.todo_row :for={todo <- list.todos} todo={todo} offline={true} status={Map.get(@status_by_id, todo.id)} />
        <p :if={list.todos == []} class="empty-state">No todos in this list yet.</p>
      </.list_section>

      <section :if={Enum.any?(@todos, &is_nil(&1.list_id))} class="panel">
        <h2>Unlisted todos</h2>
        <.todo_row :for={todo <- @todos} :if={is_nil(todo.list_id)} todo={todo} offline={true} status={Map.get(@status_by_id, todo.id)} />
      </section>
      <p :if={@todos == [] and @lists == []} class="empty-state">Create a list or add your first todo.</p>
    </div>
    """
  end

  # --- view helpers ------------------------------------------------------

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
