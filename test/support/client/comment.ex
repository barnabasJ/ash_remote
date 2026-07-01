defmodule AshRemote.Client.Comment do
  @moduledoc "Hand-written mirror (M2) of the backend Comment."
  use Ash.Resource,
    domain: AshRemote.Client.Domain,
    data_layer: AshRemote.DataLayer

  attributes do
    uuid_primary_key :id
    attribute :body, :string, public?: true, allow_nil?: false
  end

  relationships do
    belongs_to :todo, AshRemote.Client.Todo, public?: true, attribute_writable?: true
    belongs_to :user, AshRemote.Client.User, public?: true, attribute_writable?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
