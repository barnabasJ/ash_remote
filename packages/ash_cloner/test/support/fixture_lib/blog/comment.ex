defmodule AshClonerFixtures.Blog.Comment do
  @moduledoc false
  use Ash.Resource,
    domain: AshClonerFixtures.Blog.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read]

    create :create do
      accept [:text]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :text, :string, public?: true
  end

  relationships do
    belongs_to :post, AshClonerFixtures.Blog.Post
  end
end
