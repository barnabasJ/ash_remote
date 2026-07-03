defmodule AshRemote.Client.User do
  @moduledoc "Hand-written mirror (M2) of the backend User, on AshRemote.DataLayer."
  use Ash.Resource,
    domain: AshRemote.Client.Domain,
    data_layer: AshRemote.DataLayer

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:email, :string, public?: true)
  end

  relationships do
    has_many(:todos, AshRemote.Client.Todo, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
