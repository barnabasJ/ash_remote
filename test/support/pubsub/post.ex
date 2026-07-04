defmodule AshRemote.PubSubFixture.Post do
  @moduledoc """
  ETS resource with `AshRemote.Server.Notifier` attached, used to assert the raw
  broadcasts the notifier emits.
  """
  use Ash.Resource,
    domain: AshRemote.PubSubFixture.PubDomain,
    data_layer: Ash.DataLayer.Ets,
    notifiers: [AshRemote.Server.Notifier]

  ets do
    private?(false)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:published_on, :date, public?: true)
    attribute(:secret, :string, public?: false)
  end

  actions do
    defaults([:read, :destroy, create: [:title, :published_on], update: [:title, :published_on]])
  end

  validations do
    # Forces the update into an atomic — so `changeset.attributes` holds Ash
    # expressions, exercising the notifier's JSON-safe `changed` handling.
    validate(string_length(:title, min: 1))
  end
end
