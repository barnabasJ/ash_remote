defmodule AshRemote.Backend.User do
  @moduledoc false
  use Ash.Resource,
    domain: AshRemote.Backend.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(false)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:email, :string, public?: true)
  end

  identities do
    identity(:unique_email, [:email], pre_check_with: AshRemote.Backend.Domain)
  end

  relationships do
    has_many(:todos, AshRemote.Backend.Todo, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    read :get_by_id do
      get_by(:id)
    end
  end
end
