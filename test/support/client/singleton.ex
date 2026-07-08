defmodule AshRemote.Client.Singleton do
  @moduledoc "Hand-written mirror of AshRemote.Backend.Singleton — M11 fixture."
  use Ash.Resource,
    domain: AshRemote.Client.Domain,
    data_layer: AshRemote.DataLayer

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  actions do
    default_accept([:name])

    read :read do
      primary?(true)
      get?(true)
    end

    create(:create, primary?: true)
    destroy(:destroy, primary?: true)
  end
end
