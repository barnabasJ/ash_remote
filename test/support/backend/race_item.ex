defmodule AshRemote.Backend.RaceItem do
  @moduledoc """
  R-7's regression fixture: a create action that accepts a caller-supplied
  `:id`, so two concurrent upsert attempts can be forced onto the exact same
  primary key.
  """
  use Ash.Resource,
    domain: AshRemote.Backend.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(false)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:title, :string, public?: true, allow_nil?: false)
  end

  identities do
    # `Ash.DataLayer.Ets`'s own `create` silently OVERWRITES an existing PK
    # (`ETS.Set.put/2`, not `put_new`) — a plain uuid_primary_key alone
    # enforces nothing at insert time. An `identity` adds Ash's own
    # pre-insert uniqueness check, which genuinely re-queries current state
    # at request time — this is what makes the SECOND concurrent create
    # actually observe the first one's row and fail, reproducing the R-7
    # collision instead of silently clobbering it.
    identity(:unique_id, [:id], pre_check_with: AshRemote.Backend.Domain)
  end

  actions do
    default_accept([:id, :title])
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
