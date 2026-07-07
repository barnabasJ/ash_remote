defmodule AshRemote.RealtimeClient.Document do
  @moduledoc """
  Realtime client mirror of the policy-protected `AshRemote.Backend.Document`,
  used to prove per-record authorization end-to-end over a real websocket (the
  actor is established from a connect-param token).
  """
  use Ash.Resource,
    domain: AshRemote.RealtimeClient.Domain,
    data_layer: AshRemote.DataLayer,
    extensions: [AshRemote.Resource],
    notifiers: [AshRemote.RealtimeClient.CaptureNotifier]

  remote do
    source("AshRemote.Backend.Document")
    realtime?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:owner_id, :uuid, public?: true)
  end

  calculations do
    # Hand-written proxy (H1 targets `AshRemote.RemoteCalculation` directly,
    # not the generator's `remote(...)` expression form) — not selected by
    # default, so a plain read never prefetches it; `Ash.load!/3` on
    # already-fetched records is the "bundled fetch" path under test.
    calculate(:is_owner, :boolean, {AshRemote.RemoteCalculation, calc: :is_owner})
  end

  actions do
    default_accept([:title, :owner_id])
    defaults([:read, :create, :update, :destroy])
  end
end
