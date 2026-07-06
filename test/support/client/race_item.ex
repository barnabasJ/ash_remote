defmodule AshRemote.Client.RaceItem do
  @moduledoc "Client mirror of AshRemote.Backend.RaceItem (R-7 regression fixture)."
  use Ash.Resource,
    domain: AshRemote.Client.Domain,
    data_layer: AshRemote.DataLayer

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:title, :string, public?: true, allow_nil?: false)
  end

  actions do
    default_accept([:id, :title])

    read(:read, primary?: true)
    create(:create, primary?: true)
    update(:update, primary?: true)
    destroy(:destroy, primary?: true)
  end
end
