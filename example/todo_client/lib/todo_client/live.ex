defmodule TodoClient.Live do
  @moduledoc """
  A LiveView over the remote todos, fronted by `AshMultiDatalayer` (an ETS
  cache over `AshRemote.DataLayer`). Every read/write goes through the
  generated `TodoClient.Remote.*` resources.

  What the demo shows:

    * **Owner filtering** — you only see your own private lists/todos (the
      server enforces it; run a second instance as another user to compare).
    * **Public sharing** — public todos/lists are visible to everyone, live.
    * **Realtime invalidation** — `AshRemote.Realtime` re-emits server-side
      changes locally; `AshRemote.MultiDatalayer.ChangeNotifier` drops exactly
      the affected coverage-ledger entries *before* `TodoClient.RealtimeBridge`
      tells this LiveView to refetch, so the refetch is a genuine (and, for
      the affected rows, singular) miss — never a stale cache hit.
    * **Cache stats** — the sticky bar at the top, fed by `ash_multi_datalayer`
      telemetry, shows hits/misses/backfills/invalidations live. Warm a
      Browse filter, then change something on the *other* client instance:
      watch only the affected filter's coverage take a miss, everything else
      stays a hit.
    * **Two aggregate strategies** — `todo_count` is folded from the cached
      todos (0 RPC when covered); `completed_count` is opted out of folding
      and always forwarded to the server by name (1 RPC) — side by side.
  """
  use Phoenix.LiveView

  require Ash.Query

  alias TodoClient.Remote.Todo
  alias TodoClient.Remote.TodoList

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TodoClient.PubSub, TodoClient.CacheStats.topic())
      Phoenix.PubSub.subscribe(TodoClient.PubSub, TodoClient.RealtimeBridge.topic())
    end

    lists = load_lists()

    {:ok,
     socket
     |> assign(
       user: TodoClient.Session.user(),
       lists: lists,
       form: new_form(),
       browse_list_id: lists |> List.first() |> then(&(&1 && &1.id)),
       browse_status: "all",
       browse_priority: "any",
       cache_stats: TodoClient.CacheStats.stats(),
       cache_enabled?: AshMultiDatalayer.enabled?(Todo)
     )
     |> assign_browse_todos()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: 40rem; margin: 0 auto 3rem; font-family: system-ui, sans-serif;">
      <%!-- Sticky cache-stats bar — stays visible while scrolling the lists/browse panel below. --%>
      <footer style="position: sticky; top: 0; z-index: 10; margin: 0 0 1.5rem; padding: .6rem 1rem; background: #f6f6f6; border-bottom: 1px solid #ddd; display: flex; gap: 1rem; align-items: center; font-size: .85rem; color: #555;">
        <span>
          cache: <b>{@cache_stats.hits}</b> hits · <b>{@cache_stats.misses}</b> misses ·
          <b>{@cache_stats.backfills}</b> backfills · <b>{@cache_stats.invalidations}</b> invalidations
          <span :if={@cache_stats.divergences > 0} style="color:#c00;">
            · {@cache_stats.divergences} divergences
          </span>
        </span>
        <button
          phx-click="cache-toggle"
          style={"margin-left:auto; padding:.3rem .7rem; border-radius:.4rem; border:1px solid #ccc; cursor:pointer; " <>
            if(@cache_enabled?, do: "background:#e6f7e6;", else: "background:#fbeaea;")}
        >
          cache {if @cache_enabled?, do: "ON", else: "OFF"}
        </button>
      </footer>

      <header style="display:flex; align-items:baseline; gap:.75rem; margin-bottom:1.5rem; padding: 0 .5rem;">
        <h1 style="margin:0;">Todos</h1>
        <small style="color:#888;">
          signed in as <strong>{@user && @user["email"]}</strong> · ash_remote + ash_multi_datalayer
        </small>
      </header>

      <p
        :if={info = Phoenix.Flash.get(@flash, :info)}
        style="margin: 0 .5rem 1rem; padding:.5rem .75rem; background:#e6f4ff; color:#0353a4; border-radius:.4rem; font-size:.85rem;"
      >
        {info}
      </p>
      <p
        :if={error = Phoenix.Flash.get(@flash, :error)}
        style="margin: 0 .5rem 1rem; padding:.5rem .75rem; background:#fbeaea; color:#c00; border-radius:.4rem; font-size:.85rem;"
      >
        {error}
      </p>

      <div style="padding: 0 .5rem;">
        <form phx-submit="add_list" style="display:flex; gap:.5rem; margin-bottom:1.5rem;">
          <input name="name" placeholder="New list name…" required style="flex:1; padding:.4rem;" />
          <label style="display:flex; align-items:center; gap:.25rem; font-size:.85rem;">
            <input type="checkbox" name="public" value="true" /> public
          </label>
          <button style="padding:.4rem .8rem;">Add list</button>
        </form>

        <section :for={list <- @lists} style="margin-bottom:1.5rem;">
          <h2 style="display:flex; align-items:baseline; gap:.5rem; border-bottom:2px solid #eee; padding-bottom:.3rem; flex-wrap: wrap;">
            {list.name}
            <.badge :if={list.public} />
            <small style="margin-left:auto;color:#888;font-weight:400;">
              <span title="native aggregate folded from the cached todos — 0 RPC on a warm reload">
                {list.todo_count} todos <span style="color:#2e7d32">·local</span>
              </span>
              <span title="aggregate opted out of folding — forwarded to the server by name">
                {list.completed_count} done <span style="color:#c62828">·server</span>
              </span>
            </small>
          </h2>

          <ul style="list-style: none; padding: 0;">
            <li :for={todo <- Enum.sort_by(list.todos, & &1.title)}>
              <.todo_row todo={todo} />
              <ul style="list-style: none; padding-left: 1.75rem;">
                <li :for={subtask <- Enum.sort_by(todo.subtasks, & &1.title)}>
                  <.todo_row todo={subtask} />
                </li>
              </ul>
            </li>
          </ul>
        </section>

        <.form for={@form} phx-change="validate" phx-submit="save" style="display:flex; gap:.5rem; margin-top:1rem;">
          <input
            type="text"
            name={@form[:title].name}
            value={@form[:title].value}
            placeholder="New todo"
            style="flex:1; padding:.4rem;"
          />
          <select name={@form[:list_id].name} style="padding:.4rem;">
            <option :for={list <- @lists} value={list.id} selected={@form[:list_id].value == list.id}>
              {list.name}
            </option>
          </select>
          <button type="submit" style="padding:.4rem .8rem;">Add</button>
        </.form>
        <%!-- Errors from the mirrored validations — raised client-side, no RPC. --%>
        <p :for={error <- @form[:title].errors} style="color:#c00; margin:.3rem 0 0;">
          title {error_text(error)}
        </p>

        <%!-- Browse panel: plain-attribute filtered reads — the cache-eligible
             workload. Flip between tabs and watch the RPC log go quiet while
             the hit counter climbs. --%>
        <section style="margin-top:2.5rem; border-top:2px solid #ddd; padding-top:1rem;">
          <h2 style="display:flex; align-items:baseline; gap:.5rem;">
            Browse
            <small style="color:#888;font-weight:400">cached filtered reads via ash_multi_datalayer</small>
          </h2>

          <div style="display:flex; gap:.5rem; flex-wrap:wrap; margin-bottom:.75rem;">
            <form phx-change="browse-list" style="display:contents;">
              <select name="browse_list" style="padding:.3rem;">
                <option
                  :for={list <- @lists}
                  value={list.id}
                  selected={@browse_list_id == list.id}
                >
                  {list.name}
                </option>
              </select>
            </form>

            <span style="display:inline-flex; border:1px solid #ccc; border-radius:.4rem; overflow:hidden;">
              <button
                :for={status <- ~w(all active done)}
                phx-click="browse-status"
                phx-value-status={status}
                style={tab_style(@browse_status == status)}
              >
                {status}
              </button>
            </span>

            <span style="display:inline-flex; border:1px solid #ccc; border-radius:.4rem; overflow:hidden;">
              <button
                :for={priority <- ~w(any low medium high)}
                phx-click="browse-priority"
                phx-value-priority={priority}
                style={tab_style(@browse_priority == priority)}
              >
                {priority}
              </button>
            </span>
          </div>

          <ul style="list-style:none; padding:0;">
            <li
              :for={todo <- @browse_todos}
              style="display:flex; gap:.75rem; padding:.3rem 0; border-bottom:1px solid #eee;"
            >
              <span style={"flex:1;" <> if(todo.completed, do: "color:#999;text-decoration:line-through;", else: "")}>
                {todo.title}
              </span>
              <span style="font-size:.75rem;color:#888;">{todo.priority}</span>
              <span :if={todo.due_date} style="font-size:.75rem;color:#888;">{todo.due_date}</span>
            </li>
          </ul>
          <p :if={@browse_todos == []} style="color:#888;">nothing here</p>
        </section>
      </div>
    </div>
    """
  end

  defp badge(assigns) do
    ~H"""
    <span style="font-size:.65rem; background:#e8f0fe; color:#1a56db; padding:.1rem .4rem; border-radius:.5rem;">
      PUBLIC
    </span>
    """
  end

  defp tab_style(true),
    do: "padding:.3rem .7rem; border:0; background:#333; color:#fff; cursor:pointer;"

  defp tab_style(false), do: "padding:.3rem .7rem; border:0; background:#fff; cursor:pointer;"

  defp error_text({message, vars}) do
    Enum.reduce(vars, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp error_text(message), do: to_string(message)

  defp todo_row(assigns) do
    ~H"""
    <div style="display:flex; align-items:center; gap:.5rem; padding:.4rem 0; border-bottom:1px solid #eee;">
      <input type="checkbox" checked={@todo.completed} phx-click="toggle" phx-value-id={@todo.id} />
      <span style={"flex:1;" <> if(@todo.completed, do: "text-decoration:line-through;color:#999;", else: "")}>
        {@todo.title}
      </span>
      <span
        :if={@todo.overdue?}
        style="font-size:.7rem;color:#fff;background:#c00;border-radius:.5rem;padding:.1rem .5rem;"
      >
        overdue
      </span>
      <span style="font-size:.75rem;color:#888;">{@todo.priority}</span>
      <button phx-click="delete" phx-value-id={@todo.id} style="border:0;background:none;cursor:pointer;color:#c00;">✕</button>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"todo" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form.source, params)
    {:noreply, assign(socket, form: to_form(form))}
  end

  def handle_event("save", %{"todo" => params}, socket) do
    params = Map.put(params, "public", list_public?(socket, params["list_id"]))

    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _todo} ->
        {:noreply,
         socket |> assign(lists: load_lists(), form: new_form()) |> assign_browse_todos()}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def handle_event("add_list", params, socket) do
    TodoList
    |> Ash.Changeset.for_create(
      :create,
      %{name: params["name"], public: params["public"] == "true"},
      actor: actor()
    )
    |> Ash.create()

    {:noreply, socket |> assign(lists: load_lists()) |> assign_browse_todos()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    result =
      case Ash.get(Todo, id, actor: actor()) do
        {:ok, todo} ->
          todo
          |> Ash.Changeset.for_update(:update, %{completed: not todo.completed}, actor: actor())
          |> Ash.update(actor: actor())

        error ->
          error
      end

    {:noreply, reconcile_if_stale(socket, id, result)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    result =
      case Ash.get(Todo, id, actor: actor()) do
        {:ok, todo} -> Ash.destroy(todo, actor: actor())
        error -> error
      end

    {:noreply, reconcile_if_stale(socket, id, result)}
  end

  def handle_event("browse-list", %{"browse_list" => id}, socket) do
    {:noreply, socket |> assign(browse_list_id: id) |> assign_browse_todos()}
  end

  def handle_event("browse-status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(browse_status: status) |> assign_browse_todos()}
  end

  def handle_event("browse-priority", %{"priority" => priority}, socket) do
    {:noreply, socket |> assign(browse_priority: priority) |> assign_browse_todos()}
  end

  def handle_event("cache-toggle", _params, socket) do
    toggle = if socket.assigns.cache_enabled?, do: :disable!, else: :enable!

    for resource <- [Todo, TodoList] do
      apply(AshMultiDatalayer, toggle, [resource])
    end

    {:noreply,
     socket
     |> assign(cache_enabled?: AshMultiDatalayer.enabled?(Todo))
     |> assign_browse_todos()}
  end

  @impl true
  def handle_info({:cache_stats, stats}, socket) do
    {:noreply, assign(socket, cache_stats: stats)}
  end

  def handle_info({:remote_change, _resource, _type}, socket) do
    # A change we're allowed to see arrived over the realtime socket. By now
    # AshRemote.MultiDatalayer.ChangeNotifier has already dropped the affected
    # coverage entries (it ran first — see TodoClient.Remote.Todo's
    # `notifiers:`), so this refetch is a genuine miss for the affected rows,
    # not a stale hit.
    {:noreply, socket |> assign(lists: load_lists()) |> assign_browse_todos()}
  end

  # A cached row can go stale with no signal at all: `ash_remote` documents
  # realtime notifications as at-most-once with no replay, so a push can be
  # dropped with no accompanying disconnect for AshRemote.MultiDatalayer.LifecycleGuard
  # to react to either. When that happens, the first sign is *this* client
  # discovering it directly — acting on the cached row 404s against the real
  # backend. Treat that discovery as the missed notification's belated
  # arrival: purge the stale coverage via AshMultiDatalayer.forget!/3 (the same
  # invalidation AshRemote.MultiDatalayer.ChangeNotifier would have run had the
  # push actually arrived) instead of leaving an undeletable ghost forever.
  defp reconcile_if_stale(socket, _id, :ok), do: refresh(socket)
  defp reconcile_if_stale(socket, _id, {:ok, _record}), do: refresh(socket)

  defp reconcile_if_stale(socket, id, {:error, error}) do
    socket =
      if AshMultiDatalayer.not_found?(error) do
        AshMultiDatalayer.forget!(Todo, %{id: id})
        put_flash(socket, :info, "That todo was already removed elsewhere — refreshed.")
      else
        put_flash(socket, :error, "That action couldn't be completed.")
      end

    refresh(socket)
  end

  defp refresh(socket), do: socket |> assign(lists: load_lists()) |> assign_browse_todos()

  defp actor, do: TodoClient.Session.actor()

  defp list_public?(socket, list_id) do
    case Enum.find(socket.assigns.lists, &(&1.id == list_id)) do
      %{public: public} -> public
      _ -> false
    end
  end

  # The cache-eligible workload: plain attribute filters, no calculations or
  # aggregates. A broad list read warms the cache; the narrower status and
  # priority filters are then proven subsets, served from ETS with no RPC.
  defp assign_browse_todos(%{assigns: %{browse_list_id: nil}} = socket) do
    assign(socket, browse_todos: [])
  end

  defp assign_browse_todos(socket) do
    %{browse_list_id: list_id, browse_status: status, browse_priority: priority} =
      socket.assigns

    query = Ash.Query.filter(Todo, list_id == ^list_id)

    query =
      case status do
        "active" -> Ash.Query.filter(query, completed == false)
        "done" -> Ash.Query.filter(query, completed == true)
        _all -> query
      end

    query =
      case priority do
        "any" -> query
        value -> Ash.Query.filter(query, priority == ^String.to_existing_atom(value))
      end

    assign(
      socket,
      browse_todos: query |> Ash.Query.sort(:title) |> Ash.read!(actor: actor())
    )
  end

  defp load_lists do
    TodoList
    |> Ash.Query.sort(:name)
    |> Ash.Query.load([
      :todo_count,
      :completed_count,
      todos: [:overdue?, subtasks: [:overdue?]]
    ])
    |> Ash.read!(actor: actor())
  end

  defp new_form do
    Todo |> AshPhoenix.Form.for_create(:create, as: "todo", actor: actor()) |> to_form()
  end
end
