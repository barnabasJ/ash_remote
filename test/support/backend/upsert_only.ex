defmodule AshRemote.Backend.UpsertOnly do
  @moduledoc """
  `server_upserts?` regression fixture: mirrors mob_worker's real `Evv.Event`
  shape — the only read is non-primary and argument-gated (no unfiltered
  list, as a worker-scoped resource must never leak other workers' rows),
  and `create` is itself an idempotent upsert on a client-supplied identity
  (`upsert_fields: []`, so a re-flushed create is a no-op, not a collision).
  """
  use Ash.Resource,
    domain: AshRemote.Backend.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? false
  end

  actions do
    default_accept [:id, :token, :title]

    read :by_token do
      argument :token, :string, allow_nil?: false
      filter expr(token == ^arg(:token))
    end

    create :create do
      primary? true
      upsert? true
      upsert_identity :unique_token
      upsert_fields []
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :token, :string, public?: true, allow_nil?: false
    attribute :title, :string, public?: true, allow_nil?: false
  end

  identities do
    identity :unique_token, [:token], pre_check_with: AshRemote.Backend.Domain
  end
end
