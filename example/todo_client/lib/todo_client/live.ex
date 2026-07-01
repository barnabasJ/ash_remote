defmodule TodoClient.Live do
  @moduledoc """
  A LiveView that manages todos living on the remote backend.

  Every read/write goes through the generated `TodoClient.Remote.Todo` resource,
  which `AshRemote.DataLayer` turns into `/rpc/run` calls — the LiveView never
  talks HTTP directly. Creates use `AshPhoenix.Form`, exactly as they would for a
  local Ash resource.
  """
  use Phoenix.LiveView

  require Ash.Query

  alias TodoClient.Remote.Todo

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, todos: list_todos(), form: new_form())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: 32rem; margin: 3rem auto; font-family: system-ui, sans-serif;">
      <h1>Todos <small style="color:#888;font-weight:400">via ash_remote</small></h1>

      <ul style="list-style: none; padding: 0;">
        <li :for={todo <- @todos} style="display:flex; align-items:center; gap:.5rem; padding:.4rem 0; border-bottom:1px solid #eee;">
          <input type="checkbox" checked={todo.completed} phx-click="toggle" phx-value-id={todo.id} />
          <span style={"flex:1;" <> if(todo.completed, do: "text-decoration:line-through;color:#999;", else: "")}>
            {todo.title}
          </span>
          <span style="font-size:.75rem;color:#888;">{todo.priority}</span>
          <button phx-click="delete" phx-value-id={todo.id} style="border:0;background:none;cursor:pointer;color:#c00;">✕</button>
        </li>
      </ul>

      <.form for={@form} phx-change="validate" phx-submit="save" style="display:flex; gap:.5rem; margin-top:1rem;">
        <input
          type="text"
          name={@form[:title].name}
          value={@form[:title].value}
          placeholder="New todo"
          style="flex:1; padding:.4rem;"
        />
        <button type="submit" style="padding:.4rem .8rem;">Add</button>
      </.form>
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
      {:ok, _todo} -> {:noreply, assign(socket, todos: list_todos(), form: new_form())}
      {:error, form} -> {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    todo = Enum.find(socket.assigns.todos, &(&1.id == id))
    Ash.update!(todo, %{completed: not todo.completed})
    {:noreply, assign(socket, todos: list_todos())}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    todo = Enum.find(socket.assigns.todos, &(&1.id == id))
    Ash.destroy!(todo)
    {:noreply, assign(socket, todos: list_todos())}
  end

  defp list_todos, do: Todo |> Ash.Query.sort(:title) |> Ash.read!()

  defp new_form, do: Todo |> AshPhoenix.Form.for_create(:create, as: "todo") |> to_form()
end
