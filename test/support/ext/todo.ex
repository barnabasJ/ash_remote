defmodule AshRemote.Ext.Todo do
  @moduledoc "Minimal resource exercising the `remote do ... end` section (M3)."
  use Ash.Resource,
    domain: AshRemote.Ext.Domain,
    data_layer: AshRemote.DataLayer

  remote do
    source "AshRemote.Backend.Todo"
    action_map read: :read
    schema_version "1.0.0"
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
  end
end

defmodule AshRemote.Ext.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshRemote.Ext.Todo
  end
end
