defmodule AshRemote.Client.CompositeItem do
  @moduledoc "Client mirror of AshRemote.Backend.CompositeItem (L7-3 composite-PK regression fixture)."
  use Ash.Resource,
    domain: AshRemote.Client.Domain,
    data_layer: AshRemote.DataLayer

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

  calculations do
    # Not prefetched by default (module calc, no expression) — `Ash.load!/3`
    # on already-fetched records is the "bundled fetch" path
    # (`fetch_remote_calculations/5`) under test.
    calculate(:shout_title, :string, {AshRemote.RemoteCalculation, calc: :shout_title})
  end

  actions do
    default_accept([:id, :tenant, :title])

    read(:read, primary?: true)
    create(:create, primary?: true)
    update(:update, primary?: true)
    destroy(:destroy, primary?: true)
  end
end
