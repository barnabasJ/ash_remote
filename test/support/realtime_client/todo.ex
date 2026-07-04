defmodule AshRemote.RealtimeClient.Todo do
  @moduledoc """
  A realtime-enabled client mirror of `AshRemote.Backend.Todo` (via
  `AshRemote.DataLayer`), with a capture notifier so tests can observe the
  notifications replicated from the server. `base_url` falls back to
  `config :ash_remote, :base_url` (the HTTP RPC endpoint).
  """
  use Ash.Resource,
    domain: AshRemote.RealtimeClient.Domain,
    data_layer: AshRemote.DataLayer,
    extensions: [AshRemote.Resource],
    notifiers: [AshRemote.RealtimeClient.CaptureNotifier]

  remote do
    source("AshRemote.Backend.Todo")
    realtime?(true)
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
    defaults([:read, :create, :update, :destroy])
  end
end
