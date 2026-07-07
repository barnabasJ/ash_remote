defmodule AshRemote.Backend.Comment do
  @moduledoc false
  use Ash.Resource,
    domain: AshRemote.Backend.Domain,
    data_layer: Ash.DataLayer.Ets,
    notifiers: [AshRemote.Server.Notifier]

  ets do
    private?(false)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:body, :string, public?: true, allow_nil?: false)
    # M7: gives an aggregate something decimal-typed to :avg/:sum over.
    attribute(:rating, :decimal, public?: true)
  end

  relationships do
    belongs_to :todo, AshRemote.Backend.Todo do
      public?(true)
      attribute_writable?(true)
    end

    belongs_to :user, AshRemote.Backend.User do
      public?(true)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
