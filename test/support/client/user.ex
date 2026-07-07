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

  identities do
    # Mirrors the backend's `unique_email` identity (H2: exercises a non-PK
    # `upsert_identity`).
    identity(:unique_email, [:email])
  end

  actions do
    defaults([:read, :destroy, create: :*])

    # H2: deliberately narrower than `create`'s accept — a replicated
    # write's upsert-resolved update must still converge `:name` even
    # though this primary update action doesn't accept it.
    update :update do
      primary?(true)
      accept([:email])
    end

    create :upsert_by_email do
      accept([:name, :email])
      upsert?(true)
      upsert_identity(:unique_email)
    end
  end
end
