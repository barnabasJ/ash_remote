defmodule TodoClient.Live do
  @moduledoc """
  A LiveView over the remote todos. This instance is signed in as one user
  (`TodoClient.Session`); every read/write goes through the generated
  `TodoClient.Remote.*` resources — `AshRemote.DataLayer` turns them into
  authenticated `/rpc/run` calls (the JWT rides the actor, auto-forwarded as a
  Bearer token).

  What the demo shows:

    * **Owner filtering** — you only see your own private lists/todos (the server
      enforces it; run a second instance as another user to compare).
    * **Public sharing** — public todos are visible to everyone.
    * **Realtime** — `AshRemote.Realtime` re-emits server-side changes locally
      (`TodoClient.RealtimeBridge` → PubSub); this view refetches. Because the
      server filters per-record, you're only pushed changes you may see, so a
      public todo created anywhere appears here live, a private one does not.
  """
  use Phoenix.LiveView

  alias TodoClient.Remote.{Todo, TodoList}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TodoClient.PubSub, TodoClient.RealtimeBridge.topic())
    end

    {:ok, socket |> assign(user: TodoClient.Session.user()) |> load_lists()}
  end

  @impl true
  def handle_info({:remote_change, _resource, _type}, socket) do
    # A change we're allowed to see arrived over the realtime socket — refetch.
    {:noreply, load_lists(socket)}
  end

  @impl true
  def handle_event("add_todo", %{"title" => title, "list_id" => list_id}, socket) do
    # A todo inherits its list's visibility: everything in a public list is
    # shared, everything in a private list is owner-only.
    Todo
    |> Ash.Changeset.for_create(
      :create,
      %{title: title, list_id: list_id, public: list_public?(socket, list_id)},
      actor: actor()
    )
    |> Ash.create()

    {:noreply, load_lists(socket)}
  end

  def handle_event("toggle", %{"id" => id, "completed" => completed}, socket) do
    Todo
    |> Ash.get!(id, actor: actor())
    |> Ash.Changeset.for_update(:update, %{completed: completed == "false"}, actor: actor())
    |> Ash.update()

    {:noreply, load_lists(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Todo |> Ash.get!(id, actor: actor()) |> Ash.destroy(actor: actor())
    {:noreply, load_lists(socket)}
  end

  def handle_event("add_list", %{"name" => name} = params, socket) do
    TodoList
    |> Ash.Changeset.for_create(:create, %{name: name, public: params["public"] == "true"},
      actor: actor()
    )
    |> Ash.create()

    {:noreply, load_lists(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: 40rem; margin: 2.5rem auto; font-family: system-ui, sans-serif;">
      <header style="display:flex; align-items:baseline; gap:.75rem; margin-bottom:1.5rem;">
        <h1 style="margin:0;">Todos</h1>
        <small style="color:#888;">
          signed in as <strong>{@user && @user["email"]}</strong> · live via ash_remote
        </small>
      </header>

      <form phx-submit="add_list" style="display:flex; gap:.5rem; margin-bottom:1.5rem;">
        <input name="name" placeholder="New list name…" required style="flex:1; padding:.4rem;" />
        <label style="display:flex; align-items:center; gap:.25rem; font-size:.85rem;">
          <input type="checkbox" name="public" value="true" /> public
        </label>
        <button style="padding:.4rem .8rem;">Add list</button>
      </form>

      <section :for={list <- @lists} style="margin-bottom:1.5rem;">
        <h2 style="display:flex; align-items:baseline; gap:.5rem; border-bottom:2px solid #eee; padding-bottom:.3rem;">
          {list.name}
          <.badge :if={list.public} />
          <small style="margin-left:auto;color:#888;font-weight:400;">{list.todo_count} items</small>
        </h2>

        <ul style="list-style:none; padding:0;">
          <li
            :for={todo <- Enum.sort_by(list.todos, & &1.title)}
            style="display:flex; align-items:center; gap:.5rem; padding:.15rem 0;"
          >
            <input
              type="checkbox"
              checked={todo.completed}
              phx-click="toggle"
              phx-value-id={todo.id}
              phx-value-completed={to_string(todo.completed)}
            />
            <span style={todo.completed && "text-decoration:line-through;color:#aaa;"}>
              {todo.title}
            </span>
            <button
              phx-click="delete"
              phx-value-id={todo.id}
              style="margin-left:auto;border:0;background:none;cursor:pointer;color:#c00;"
            >
              ×
            </button>
          </li>
        </ul>

        <form phx-submit="add_todo" style="display:flex; gap:.4rem; margin-top:.4rem;">
          <input type="hidden" name="list_id" value={list.id} />
          <input name="title" placeholder="Add a todo…" required style="flex:1; padding:.3rem;" />
          <button style="padding:.3rem .6rem;">Add</button>
        </form>
      </section>
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

  defp actor, do: TodoClient.Session.actor()

  defp list_public?(socket, list_id) do
    case Enum.find(socket.assigns.lists, &(&1.id == list_id)) do
      %{public: public} -> public
      _ -> false
    end
  end

  defp load_lists(socket) do
    lists =
      TodoList
      |> Ash.Query.load([:todos, :todo_count])
      |> Ash.read!(actor: actor())
      |> Enum.sort_by(& &1.name)

    assign(socket, lists: lists)
  end
end
