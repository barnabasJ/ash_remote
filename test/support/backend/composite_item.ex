defmodule AshRemote.Backend.CompositeItem do
  @moduledoc """
  L7-3 fixture: a 2-attribute composite primary key (`id` + `tenant`), with
  a calculation the client proxies via `AshRemote.RemoteCalculation` —
  exercises `AshRemote.DataLayer.fetch_remote_calculations/5`'s bundled-fetch
  path (`Ash.load!/3` on already-fetched records), where
  `[pk] = Ash.Resource.Info.primary_key(resource)` used to crash with
  `MatchError` for any non-single-attribute primary key.
  """
  use Ash.Resource,
    domain: AshRemote.Backend.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(false)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)

    attribute :tenant, :string do
      primary_key?(true)
      allow_nil?(false)
      writable?(true)
      public?(true)
    end

    attribute(:title, :string, public?: true, allow_nil?: false)
  end

  actions do
    default_accept([:id, :tenant, :title])
    defaults([:read, :destroy, create: :*, update: :*])
  end

  calculations do
    calculate :shout_title, :string, expr(title) do
      public?(true)
    end
  end
end
