defmodule AshRemote.Client.Note do
  @moduledoc "Hand-written mirror of the backend's context-multitenant Note (R-1 regression)."
  use Ash.Resource,
    domain: AshRemote.Client.Domain,
    data_layer: AshRemote.DataLayer

  multitenancy do
    strategy(:context)
    global?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:text, :string, public?: true, allow_nil?: false)
  end

  actions do
    default_accept([:text])

    read(:read, primary?: true)
    create(:create, primary?: true)
    update(:update, primary?: true)
    destroy(:destroy, primary?: true)
  end
end
