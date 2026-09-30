defmodule TodoClient.Components do
  @moduledoc "Shared presentation and form components for both todo demos."
  use Phoenix.Component

  attr(:flash, :map, required: true)

  def notices(assigns) do
    ~H"""
    <div :for={kind <- [:info, :error]} :if={message = Phoenix.Flash.get(@flash, kind)} class={"notice notice-#{kind}"} role={if(kind == :error, do: "alert", else: "status")}>
      <span>{message}</span>
      <button type="button" phx-click="dismiss-flash" phx-value-kind={kind} aria-label={"Dismiss #{kind} message"}>×</button>
    </div>
    """
  end

  attr(:name, :string, default: "")
  attr(:public, :boolean, default: false)

  def list_form(assigns) do
    ~H"""
    <form phx-submit="add_list" class="entry-form">
      <input name="name" value={@name} placeholder="New list name…" aria-label="New list name" required />
      <label class="check-label"><input type="checkbox" name="public" value="true" checked={@public} /> Public list</label>
      <button class="primary-button">Create list</button>
    </form>
    """
  end

  attr(:lists, :list, required: true)
  attr(:title, :string, default: "")
  attr(:list_id, :string, default: nil)
  attr(:public, :boolean, default: false)
  attr(:errors, :list, default: [])
  attr(:allow_unlisted, :boolean, default: false)

  def todo_form(assigns) do
    ~H"""
    <form phx-change="validate" phx-submit="save" class="entry-form">
      <input name="todo[title]" value={@title} placeholder="New todo…" aria-label="New todo title" required />
      <select name="todo[list_id]" aria-label="Todo list">
        <option :if={@allow_unlisted} value="" selected={is_nil(@list_id) or @list_id == ""}>No list</option>
        <option :for={list <- @lists} value={list.id} selected={@list_id == list.id or (!@allow_unlisted and is_nil(@list_id) and list == hd(@lists))}>{list.name}</option>
      </select>
      <input type="hidden" name="todo[public]" value="false" />
      <label class="check-label"><input type="checkbox" name="todo[public]" value="true" checked={@public} /> Public todo</label>
      <button class="primary-button" disabled={!@allow_unlisted and @lists == []}>Add todo</button>
    </form>
    <p :if={!@allow_unlisted and @lists == []} class="empty-state">Create a list to add a todo.</p>
    <p :for={error <- @errors} class="form-error">{error}</p>
    """
  end

  attr(:list, :map, required: true)
  slot(:inner_block, required: true)

  def list_section(assigns) do
    ~H"""
    <section class="list-card">
      <header class="list-heading">
        <h2>{@list.name}</h2>
        <span class={if(@list.public, do: "visibility public", else: "visibility private")}>
          {if @list.public, do: "🌐 Public", else: "🔒 Private"}
        </span>
        <small>{@list.todo_count} todos · {@list.completed_count} done</small>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr(:todo, :map, required: true)
  attr(:status, :any, default: nil)
  attr(:source, :string, default: nil)
  attr(:offline, :boolean, default: false)

  def todo_row(assigns) do
    ~H"""
    <div class="todo-row">
      <button type="button" role="checkbox" aria-checked={to_string(@todo.completed)} aria-label={"Toggle #{@todo.title}"} phx-click="toggle" phx-value-id={@todo.id} class="toggle-button">
        {if @todo.completed, do: "☑", else: "☐"}
      </button>
      <form :if={@offline} phx-submit="rename" class="todo-title-form">
        <input type="hidden" name="todo_id" value={@todo.id} />
        <input name="title" value={@todo.title} aria-label={"Rename #{@todo.title}"} class={if(@todo.completed, do: "done", else: "")} />
      </form>
      <span :if={!@offline} class={"todo-title #{if(@todo.completed, do: "done", else: "")}"}>{@todo.title}</span>
      <span :if={Map.get(@todo, :overdue?) == true} class="pill overdue">overdue</span>
      <span :if={@todo.public} class="pill public">public</span>
      <span class="pill muted">{@todo.priority}</span>
      <span :if={@source} class="pill source">{@source}</span>
      <span :if={@status} class={"pill #{status_class(@status)}"}>{status_label(@status)}</span>
      <button type="button" phx-click="delete" phx-value-id={@todo.id} class="delete-button" aria-label={"Delete #{@todo.title}"}>×</button>
    </div>
    """
  end

  defp status_class(:synced), do: "synced"
  defp status_class(:pending), do: "pending"
  defp status_class({:parked, _}), do: "parked"
  defp status_class(_), do: "muted"
  defp status_label({:parked, _}), do: "parked"
  defp status_label(status), do: to_string(status)
end
