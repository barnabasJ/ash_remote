defmodule TodoMob.TodoListScreen do
  @moduledoc """
  A mob screen that manages todos living on the remote backend.

  Every read and write goes through the generated `TodoMob.Remote.Todo`
  resource, which `AshRemote.DataLayer` turns into `/rpc/run` calls — the screen
  never talks HTTP directly. Creates are driven by `AshPhoenix.Form`, exactly as
  they would be for a local Ash resource.

  On a real device this renders native SwiftUI/Compose from the `~MOB` template;
  here it runs headlessly (see `TodoMob.Demo` / the test) so the full
  screen → ash_remote → server loop is exercised without an emulator.
  """
  use Mob.Screen

  require Ash.Query

  alias TodoMob.Remote.Todo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Mob.Socket.assign(:todos, list_todos())
     |> Mob.Socket.assign(:form, new_form())}
  end

  @impl true
  # The real mob compiler binds `assigns` into the template's `{@...}` refs; the
  # shim returns it verbatim, so `assigns` is unused here.
  def render(_assigns) do
    ~MOB"""
    <Column padding={20} gap={12}>
      <Text text="Todos" text_size={:xl} />

      <For each={@todos}>
        <Row gap={8} align={:center}>
          <Button
            text={if(todo.completed, do: "☑", else: "☐")}
            on_tap={tap({:toggle, todo.id})}
          />
          <Text text={todo.title} strikethrough={todo.completed} />
          <Spacer />
          <Badge text={to_string(todo.priority)} />
          <Button text="✕" on_tap={tap({:delete, todo.id})} />
        </Row>
      </For>

      <Row gap={8}>
        <TextField placeholder="New todo" value={@form[:title].value} on_change={change(:title)} />
        <Button text="Add" on_tap={tap(:create)} />
      </Row>
    </Column>
    """
  end

  # --- events --------------------------------------------------------------

  @impl true
  def handle_info({:tap, {:toggle, id}}, socket) do
    todo = Enum.find(socket.assigns.todos, &(&1.id == id))
    {:ok, _updated} = Ash.update(todo, %{completed: not todo.completed})
    {:noreply, Mob.Socket.assign(socket, :todos, list_todos())}
  end

  def handle_info({:tap, {:delete, id}}, socket) do
    todo = Enum.find(socket.assigns.todos, &(&1.id == id))
    :ok = Ash.destroy!(todo)
    {:noreply, Mob.Socket.assign(socket, :todos, list_todos())}
  end

  # Text field edits update the AshPhoenix.Form (client-side validation).
  def handle_info({:change, params}, socket) do
    {:noreply, Mob.Socket.assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  # Submit the create form → remote create over RPC.
  def handle_info({:tap, :create}, socket) do
    # params were applied via {:change} → validate; submit the validated form.
    case AshPhoenix.Form.submit(socket.assigns.form, params: nil) do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> Mob.Socket.assign(:todos, list_todos())
         |> Mob.Socket.assign(:form, new_form())}

      {:error, form} ->
        {:noreply, Mob.Socket.assign(socket, :form, form)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # --- data ----------------------------------------------------------------

  defp list_todos do
    Todo
    |> Ash.Query.sort(title: :asc)
    |> Ash.read!()
  end

  defp new_form do
    AshPhoenix.Form.for_create(Todo, :create, forms: [])
  end
end
