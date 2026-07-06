defmodule TodoClient.Case do
  @moduledoc """
  Case template for the client's end-to-end tests: resets server data, all
  client-side layered state (cache, coverage ledger, kill-switch), the RPC
  counter, and forwards `ash_multi_datalayer` telemetry to the test process
  as `{:mdl, event, measurements, metadata}` messages.

  The signed-in user (`TodoClient.Session`, ada@example.com) is registered
  once in `test/test_helper.exs` and never destroyed here — only her
  Todo/TodoList data is reset between tests.
  """
  use ExUnit.CaseTemplate

  require Ash.Query

  alias TodoClient.Test.CountingRouter

  @client_resources [TodoClient.Remote.Todo, TodoClient.Remote.TodoList]

  @events [
    [:ash_multi_datalayer, :read, :hit],
    [:ash_multi_datalayer, :read, :miss],
    [:ash_multi_datalayer, :read, :partial],
    [:ash_multi_datalayer, :read, :backfill],
    [:ash_multi_datalayer, :write, :applied],
    [:ash_multi_datalayer, :write, :failed_at_layer],
    [:ash_multi_datalayer, :ledger, :invalidated]
  ]

  using do
    quote do
      import TodoClient.Case

      require Ash.Query

      alias TodoClient.Remote.{Todo, TodoList}
      alias TodoClient.Test.CountingRouter
    end
  end

  setup do
    ada =
      TodoServer.Accounts.User
      |> Ash.Query.filter(email == "ada@example.com")
      |> Ash.read_one!(authorize?: false)

    # Server truth: wipe this user's Todo/TodoList data (not Users — ada's
    # session must survive across the whole suite).
    Enum.each(Ash.read!(TodoServer.Todo, authorize?: false), &Ash.destroy!(&1, authorize?: false))

    Enum.each(
      Ash.read!(TodoServer.TodoList, authorize?: false),
      &Ash.destroy!(&1, authorize?: false)
    )

    # Client layered state: coverage ledgers + kill-switches (the library),
    # and the Ets cache tables (layer-specific cleanup is the app's job).
    Enum.each(@client_resources, fn resource ->
      AshMultiDatalayer.TestSupport.reset!(resource)
      Ash.DataLayer.Ets.stop(resource)
    end)

    CountingRouter.reset!()

    handler = "todo-client-case-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach_many(
      handler,
      @events,
      fn event, measurements, metadata, _config ->
        send(parent, {:mdl, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    list =
      TodoClient.Remote.TodoList
      |> Ash.Changeset.for_create(:create, %{name: "Errands"}, actor: TodoClient.Session.actor())
      |> Ash.create!(actor: TodoClient.Session.actor())

    other_list =
      TodoClient.Remote.TodoList
      |> Ash.Changeset.for_create(:create, %{name: "Later"}, actor: TodoClient.Session.actor())
      |> Ash.create!(actor: TodoClient.Session.actor())

    %{ada: ada, list: list, other_list: other_list}
  end

  @doc "Creates a todo directly on the server as ada (out-of-band for the client)."
  def server_create_todo!(attrs) do
    ada =
      TodoServer.Accounts.User
      |> Ash.Query.filter(email == "ada@example.com")
      |> Ash.read_one!(authorize?: false)

    TodoServer.Todo
    |> Ash.Changeset.for_create(:create, attrs, actor: ada)
    |> Ash.create!(actor: ada)
  end

  @doc "Registers a second user directly on the server, bypassing RPC."
  def register!(email) do
    TodoServer.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: email,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end
end
