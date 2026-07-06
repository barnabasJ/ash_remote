defmodule AshRemote.RealtimeClient.SecondTodo do
  @moduledoc """
  A SECOND realtime-enabled client mirror of the same backend source as
  `AshRemote.RealtimeClient.Todo` (`AshRemote.Backend.Todo`). Two client
  resources mapping to one server source is the real-world shape of an app that
  mixes strategies over the same backend resource (e.g. a cache mirror and a
  local-first mirror). Both must independently receive each replicated change —
  this resource exists so a test can assert that fan-out.
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
    default_accept([:title, :completed, :status, :priority_score, :due_date])
    defaults([:read, :create, :update, :destroy])
  end
end
