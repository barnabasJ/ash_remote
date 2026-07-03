defmodule TodoServer.User do
  @moduledoc false
  use Ash.Resource, domain: TodoServer.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? false
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true, allow_nil?: false
  end

  relationships do
    has_many :lists, TodoServer.TodoList, public?: true
  end

  aggregates do
    count :list_count, :lists do
      public? true
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
