defmodule TodoClient.Live do
  @moduledoc """
  A LiveView that manages todo lists living on the remote backend.

  Every read/write goes through the generated `TodoClient.Remote.*` resources,
  which `AshRemote.DataLayer` turns into `/rpc/run` calls — the LiveView never
  talks HTTP directly. One `Ash.read!` demonstrates the full loading surface:

    * aggregates (`todo_count`, `completed_count` — computed server-side),
    * a calculation (`overdue?` — the client only knows its name and type),
    * relationships (`user`, `todos`, and self-referential `subtasks`).
  """
  use Phoenix.LiveView

  require Ash.Query

  alias TodoClient.Remote.Todo
  alias TodoClient.Remote.TodoList

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, lists: load_lists(), form: new_form())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: 36rem; margin: 3rem auto; font-family: system-ui, sans-serif;">
      <h1>Todo lists <small style="color:#888;font-weight:400">via ash_remote</small></h1>

      <section :for={list <- @lists} style="margin-bottom:1.5rem;">
        <h2 style="display:flex; align-items:baseline; gap:.5rem; border-bottom:2px solid #ddd; padding-bottom:.3rem;">
          {list.name}
          <small :if={list.user} style="color:#888;font-weight:400">· {list.user.name}</small>
          <small style="margin-left:auto;color:#888;font-weight:400">
            {list.completed_count}/{list.todo_count} done
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
    </div>
    """
  end

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
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _todo} -> {:noreply, assign(socket, lists: load_lists(), form: new_form())}
      {:error, form} -> {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    todo = Ash.get!(Todo, id)
    Ash.update!(todo, %{completed: not todo.completed})
    {:noreply, assign(socket, lists: load_lists())}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Todo |> Ash.get!(id) |> Ash.destroy!()
    {:noreply, assign(socket, lists: load_lists())}
  end

  defp load_lists do
    TodoList
    |> Ash.Query.sort(:name)
    |> Ash.Query.load([
      :todo_count,
      :completed_count,
      :user,
      todos: [:overdue?, subtasks: [:overdue?]]
    ])
    |> Ash.read!()
  end

  defp new_form, do: Todo |> AshPhoenix.Form.for_create(:create, as: "todo") |> to_form()
end
