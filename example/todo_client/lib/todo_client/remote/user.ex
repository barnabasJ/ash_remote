defmodule TodoClient.Remote.User do
  use Ash.Resource,
    domain: TodoClient.Remote.Domain,
    data_layer: AshRemote.DataLayer,
    extensions: [AshRemote.Resource]

  remote do
    source("TodoServer.User")
    schema_version("1.0.0")
    managed_attributes([:id, :name])
    managed_relationships([:todos])
    managed_calculations([])
    managed_actions([:create, :read])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  relationships do
    has_many(:todos, TodoClient.Remote.Todo, public?: true)
  end

  actions do
    create :create do
      primary?(true)
      accept([:name])
    end

    read :read do
      primary?(true)
    end
  end
end
