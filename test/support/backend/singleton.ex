defmodule AshRemote.Backend.Singleton do
  @moduledoc """
  M11 fixture: a resource whose PRIMARY read action is itself `get?: true`
  — read_action_name/2 always targets the primary action, so this is the
  only way a real RPC round-trip actually exercises the server's
  single-object/explicit-null response shapes (`AshRemote.Server.get?/2`'s
  first clause).
  """
  use Ash.Resource,
    domain: AshRemote.Backend.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(false)
  end

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
