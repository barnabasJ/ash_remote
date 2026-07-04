defmodule AshRemote.RealtimeClient.PubSubTodo do
  @moduledoc """
  A realtime client mirror wired with `Ash.Notifier.PubSub` publishing to a
  `:_pkey` topic — the regression guard for the reconstructed synthetic
  changeset (PubSub dereferences `notification.changeset.resource` to fill
  `:_pkey`, so a `nil` changeset would crash).
  """
  use Ash.Resource,
    domain: AshRemote.RealtimeClient.Domain,
    data_layer: AshRemote.DataLayer,
    extensions: [AshRemote.Resource],
    notifiers: [Ash.Notifier.PubSub]

  remote do
    source("AshRemote.Backend.Todo")
    realtime?(true)
  end

  pub_sub do
    module(AshRemote.Backend.Endpoint)
    prefix("pubsub_todo")

    publish_all(:create, ["created", :_pkey])
    publish_all(:update, ["updated", :_pkey])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:completed, :boolean, public?: true, default: false, allow_nil?: false)
    attribute(:status, AshRemote.Backend.Todo.Status, public?: true)
    attribute(:priority_score, AshRemote.Backend.PriorityScore, public?: true)
    attribute(:due_date, :date, public?: true)
  end

  actions do
    default_accept([:title, :completed, :status, :priority_score, :due_date])
    defaults([:read, :create, :update, :destroy])
  end
end
