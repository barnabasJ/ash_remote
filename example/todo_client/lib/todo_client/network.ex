defmodule TodoClient.Network do
  @moduledoc """
  Demo-only RPC and notification disconnect switch. It is shared by all LiveViews in one client
  process, while Ada and Grace keep independent switches in their separate VMs.
  """

  @key {__MODULE__, :offline?}
  @topic "online_demo_network"

  def topic, do: @topic
  def offline?, do: :persistent_term.get(@key, false)
  def online?, do: not offline?()

  def set_offline!(offline?) when is_boolean(offline?) do
    reconnecting? = offline?() and not offline?
    :persistent_term.put(@key, offline?)

    if reconnecting? do
      # The notification gate discarded changes during the gap. Use the same
      # strategy-specific reconciliation as a websocket resubscription.
      for resource <- [TodoClient.Remote.Todo, TodoClient.Remote.TodoList] do
        AshRemote.MultiDatalayer.LifecycleGuard.reconcile_gap(resource)
        # ProvenCoverage drops its proof. Remove the old ETS rows as well so
        # the next read backfills only fresh server records.
        Ash.DataLayer.Ets.stop(resource)
      end

      # The offline page has a different policy: SQLite is its authority, so
      # reconcile missed remote changes into clean rows and keep dirty rows for
      # the outbox's conflict handling. This choice belongs to the demo app.
      if Process.whereis(TodoClient.Repo) do
        AshRemote.MultiDatalayer.LifecycleGuard.reconcile_gap(TodoClient.Local.Todo)
      end
    end

    if Process.whereis(TodoClient.PubSub) do
      Phoenix.PubSub.broadcast(TodoClient.PubSub, @topic, {:network, offline?})
    end

    :ok
  end
end
