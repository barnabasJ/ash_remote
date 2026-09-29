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
      telemetry, shows hits/misses/backfills/invalidations live. Each refresh
      loads lists with their todos in one Ash query; Browse reuses those rows.
  """
  use Phoenix.LiveView

  alias TodoClient.Remote.Todo
  alias TodoClient.Remote.TodoList

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TodoClient.PubSub, TodoClient.CacheStats.topic())
      Phoenix.PubSub.subscribe(TodoClient.PubSub, TodoClient.RealtimeBridge.topic())
      Phoenix.PubSub.subscribe(TodoClient.PubSub, TodoClient.Network.topic())
    end

    {:ok,
     socket
     |> assign(
       user: TodoClient.Session.user(),
       form: new_form(),
       browse_list_id: nil,
       browse_status: "all",
       browse_priority: "any",
       lists: [],
       todos: [],
       browse_todos: [],
       remote_updated_ids: MapSet.new(),
       cache_stats: TodoClient.CacheStats.stats(),
       cache_enabled?: AshMultiDatalayer.enabled?(Todo),
       offline?: TodoClient.Network.offline?()
     )
     |> refresh()}
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
          phx-click="network-toggle"
          style={"margin-left:auto; padding:.3rem .7rem; border-radius:.4rem; border:1px solid #ccc; cursor:pointer; " <>
            if(@offline?, do: "background:#fbeaea;", else: "background:#e6f7e6;")}
        >
          {if @offline?, do: "Go online", else: "Go offline"}
        </button>
        <button
          phx-click="cache-toggle"
          style={"padding:.3rem .7rem; border-radius:.4rem; border:1px solid #ccc; cursor:pointer; " <>
            if(@cache_enabled?, do: "background:#e6f7e6;", else: "background:#fbeaea;")}
        >
          cache {if @cache_enabled?, do: "ON", else: "OFF"}
        </button>
      </footer>

      <p :if={@offline?} style="margin:-1rem .5rem 1rem; padding:.55rem .75rem; border-radius:.4rem; background:#fff2e7; color:#81502a; font-size:.85rem;">
        Offline for this client. Covered reads still use ETS; uncached reads and writes fail.
        Incoming notifications are dropped until you go online.
      </p>

      <header style="display:flex; align-items:baseline; gap:.75rem; margin-bottom:1.5rem; padding: 0 .5rem;">
        <h1 style="margin:0;">Todos</h1>
        <small style="color:#888;">
          signed in as <strong>{@user && @user["email"]}</strong> · ash_remote + ash_multi_datalayer
        </small>
      </header>

      <p style="margin:-.8rem .5rem 1.2rem; color:#526173; font-size:.83rem; line-height:1.45;">
        Badges show the serving layer. A "remote update" badge marks a change received from
        another client until your next action, even if another view refilled ETS first.
      </p>

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
              <span>{list.todo_count} todos · {list.completed_count} done</span>
            </small>
          </h2>

          <ul style="list-style: none; padding: 0;">
            <li :for={todo <- Enum.sort_by(list.todos, & &1.title)}>
              <.todo_row todo={todo} remote_updated_ids={@remote_updated_ids} />
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

        <%!-- Browse filters the todos loaded by read_page/0. --%>
        <section style="margin-top:2.5rem; border-top:2px solid #ddd; padding-top:1rem;">
          <h2 style="display:flex; align-items:baseline; gap:.5rem;">
            Browse
            <small style="color:#888;font-weight:400">loaded with the lists above</small>
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
              <span :if={source = source_label(todo, @remote_updated_ids)} title="A remote update marker remains until your next action; the actual read layer is recorded on the row" style="font-size:.7rem;color:#526173;background:#edf1f5;padding:.15rem .4rem;border-radius:.35rem;">{source}</span>
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
      <button
        type="button"
        role="checkbox"
        aria-checked={to_string(@todo.completed)}
        aria-label={"Toggle #{@todo.title}"}
        phx-click="toggle"
        phx-value-id={@todo.id}
        style="border:0;background:none;padding:0;cursor:pointer;font-size:1.1rem;line-height:1;"
      >
        {if @todo.completed, do: "☑", else: "☐"}
      </button>
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
      <span :if={source = source_label(@todo, @remote_updated_ids)} title="A remote update marker remains until your next action; the actual read layer is recorded on the row" style="font-size:.7rem;color:#526173;background:#edf1f5;padding:.15rem .4rem;border-radius:.35rem;">{source}</span>
      <button phx-click="delete" phx-value-id={@todo.id} style="border:0;background:none;cursor:pointer;color:#c00;">✕</button>
    </div>
    """
  end

  defp source_label(todo, remote_updated_ids) do
    if MapSet.member?(remote_updated_ids, todo.id) do
      "remote update"
    else
      served_from_label(todo)
    end
  end

  defp served_from_label(todo) do
    case Ash.Resource.get_metadata(todo, :served_from_layer) do
      Ash.DataLayer.Ets -> "served by ETS"
      AshRemote.DataLayer -> "served by server"
      _ -> nil
    end
  end

  @impl true
  def handle_event("validate", %{"todo" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form.source, params)
    {:noreply, assign(socket, form: to_form(form))}
  end

  def handle_event("save", %{"todo" => params}, socket) do
    if socket.assigns.offline? do
      {:noreply, offline_write_flash(socket)}
    else
      params = Map.put(params, "public", list_public?(socket, params["list_id"]))

      case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
        {:ok, _todo} ->
          {:noreply, socket |> assign(form: new_form()) |> refresh()}

        {:error, form} ->
          {:noreply, assign(socket, form: to_form(form))}
      end
    end
  end

  def handle_event("add_list", params, socket) do
    if socket.assigns.offline? do
      {:noreply, offline_write_flash(socket)}
    else
      result =
        TodoList
        |> Ash.Changeset.for_create(
          :create,
          %{name: params["name"], public: params["public"] == "true"},
          actor: actor()
        )
        |> Ash.create()

      {:noreply,
       case result do
         {:ok, _list} -> refresh(socket)
         {:error, _error} -> write_error_flash(socket)
       end}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    if socket.assigns.offline? do
      {:noreply, offline_write_flash(socket)}
    else
      displayed = Enum.find(socket.assigns.todos, &(&1.id == id))

      result =
        case Ash.get(Todo, id, actor: actor()) do
          {:ok, todo} ->
            todo
            |> Ash.Changeset.for_update(
              :update,
              %{
                completed: not (displayed || todo).completed,
                expected_version: (displayed || todo).version
              },
              actor: actor()
            )
            |> Ash.update(actor: actor())

          error ->
            error
        end

      {:noreply, reconcile_if_stale(socket, id, result)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if socket.assigns.offline? do
      {:noreply, offline_write_flash(socket)}
    else
      displayed = Enum.find(socket.assigns.todos, &(&1.id == id))

      result =
        case Ash.get(Todo, id, actor: actor()) do
          {:ok, todo} ->
            todo
            |> Ash.Changeset.for_destroy(
              :destroy,
              %{expected_version: (displayed || todo).version},
              actor: actor()
            )
            |> Ash.destroy(actor: actor())

          error ->
            error
        end

      {:noreply, reconcile_if_stale(socket, id, result)}
    end
  end

  def handle_event("browse-list", %{"browse_list" => id}, socket) do
    {:noreply,
     socket
     |> assign(browse_list_id: id, remote_updated_ids: MapSet.new())
     |> assign_browse_todos()}
  end

  def handle_event("browse-status", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(browse_status: status, remote_updated_ids: MapSet.new())
     |> assign_browse_todos()}
  end

  def handle_event("browse-priority", %{"priority" => priority}, socket) do
    {:noreply,
     socket
     |> assign(browse_priority: priority, remote_updated_ids: MapSet.new())
     |> assign_browse_todos()}
  end

  def handle_event("cache-toggle", _params, socket) do
    toggle = if socket.assigns.cache_enabled?, do: :disable!, else: :enable!

    for resource <- [Todo, TodoList] do
      apply(AshMultiDatalayer, toggle, [resource])
    end

    {:noreply,
     socket
     |> assign(cache_enabled?: AshMultiDatalayer.enabled?(Todo))
     |> refresh()}
  end

  def handle_event("network-toggle", _params, socket) do
    offline? = not TodoClient.Network.offline?()
    TodoClient.Network.set_offline!(offline?)

    socket =
      if offline? do
        refresh(socket)
      else
        socket
        |> clear_flash(:error)
        |> put_flash(
          :info,
          "Online. Cache invalidated; refresh the browser to read the latest data."
        )
      end

    {:noreply, assign(socket, offline?: offline?)}
  end

  @impl true
  def handle_info({:cache_stats, stats}, socket) do
    {:noreply, assign(socket, cache_stats: stats)}
  end

  def handle_info({:network, offline?}, socket) do
    socket = assign(socket, offline?: offline?)

    {:noreply,
     if offline? do
       socket
     else
       socket
       |> clear_flash(:error)
       |> put_flash(
         :info,
         "Online. Cache invalidated; refresh the browser to read the latest data."
       )
     end}
  end

  def handle_info({:remote_change, resource, _type, id}, socket) do
    # A change we're allowed to see arrived over the realtime socket. By now
    # AshRemote.MultiDatalayer.ChangeNotifier has already dropped the affected
    # coverage entries (it ran first — see TodoClient.Remote.Todo's
    # `notifiers:`), so this refetch is a genuine miss for the affected rows,
    # not a stale hit.
    socket = refresh(socket, clear_remote?: false)

    socket =
      if resource == Todo and id do
        assign(socket, remote_updated_ids: MapSet.put(socket.assigns.remote_updated_ids, id))
      else
        socket
      end

    {:noreply, socket}
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
      cond do
        AshMultiDatalayer.not_found?(error) ->
          AshMultiDatalayer.forget!(Todo, %{id: id})
          put_flash(socket, :info, "That todo was already removed elsewhere — refreshed.")

        stale_record?(error) ->
          AshMultiDatalayer.forget!(Todo, %{id: id})

          socket
          |> clear_flash(:info)
          |> put_flash(:error, "Conflict: this todo changed elsewhere. Showing the latest version.")

        true ->
          write_error_flash(socket)
      end

    refresh(socket)
  end

  defp stale_record?(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.any?(&match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp refresh(socket, opts \\ []) do
    case read_page() do
      {:ok, {lists, todos}} ->
        assign_page(socket, lists, todos, opts)

      {:error, _error} ->
        put_flash(
          socket,
          :error,
          "Read failed: the server is unavailable and this query is not fully cached."
        )
    end
  end

  defp assign_page(socket, lists, todos, opts) do
    selected_id =
      if Enum.any?(lists, &(&1.id == socket.assigns.browse_list_id)) do
        socket.assigns.browse_list_id
      else
        lists |> List.first() |> then(&(&1 && &1.id))
      end

    socket
    |> assign(
      lists: lists,
      todos: todos,
      browse_list_id: selected_id,
      remote_updated_ids:
        if(Keyword.get(opts, :clear_remote?, true),
          do: MapSet.new(),
          else: socket.assigns.remote_updated_ids
        )
    )
    |> assign_browse_todos()
  end

  defp actor, do: TodoClient.Session.actor()

  defp list_public?(socket, list_id) do
    case Enum.find(socket.assigns.lists, &(&1.id == list_id)) do
      %{public: public} -> public
      _ -> false
    end
  end

  # Browse is a view over the rows read once by read_page/0. Changing a tab or
  # filter only changes the assigned subset; it never makes another data read.
  defp assign_browse_todos(%{assigns: %{browse_list_id: nil}} = socket) do
    assign(socket, browse_todos: [])
  end

  defp assign_browse_todos(socket) do
    %{browse_list_id: list_id, browse_status: status, browse_priority: priority} =
      socket.assigns

    todos =
      Enum.filter(socket.assigns.todos, fn todo ->
        todo.list_id == list_id and
          (status == "all" or todo.completed == (status == "done")) and
          (priority == "any" or to_string(todo.priority) == priority)
      end)

    assign(socket, browse_todos: todos)
  end

  defp read_page do
    result =
      TodoList
      |> Ash.Query.sort(:name)
      |> Ash.Query.load(todos: [:overdue?])
      |> Ash.read(actor: actor())

    case result do
      {:ok, lists} ->
        lists =
          Enum.map(lists, fn list ->
            list_todos = list.todos

            # Loading the Ash aggregates here re-reads Todo several times. These
            # counts use the complete relationship result already assigned below.
            list
            |> Map.put(:todo_count, length(list_todos))
            |> Map.put(:completed_count, Enum.count(list_todos, & &1.completed))
          end)

        {:ok, {lists, Enum.flat_map(lists, & &1.todos)}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp write_error_flash(socket) do
    if socket.assigns.offline? do
      offline_write_flash(socket)
    else
      put_flash(socket, :error, "That action couldn't be completed.")
    end
  end

  defp offline_write_flash(socket),
    do: put_flash(socket, :error, "Write failed: this client is offline. Go online to write.")

  defp new_form do
    Todo |> AshPhoenix.Form.for_create(:create, as: "todo", actor: actor()) |> to_form()
  end
end
