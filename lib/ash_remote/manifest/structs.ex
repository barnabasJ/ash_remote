defmodule AshRemote.Manifest do
  @moduledoc """
  `ash_remote`'s own normalized manifest model.

  Deliberately independent of `Ash.Info.Manifest`'s structs: the client may run
  a different Ash version than the backend, so we decode the manifest's JSON into
  these structs rather than depending on ash-core structs at runtime.
  """

  alias AshRemote.Manifest.{Resource, Type}

  @type t :: %__MODULE__{
          schema_version: String.t(),
          resources: %{String.t() => Resource.t()},
          types: %{String.t() => Type.t()},
          filter_capabilities: map(),
          sort_capabilities: map()
        }

  defstruct schema_version: nil,
            resources: %{},
            types: %{},
            filter_capabilities: %{},
            sort_capabilities: %{}

  @doc "Look up a resource by its backend module string."
  def resource(%__MODULE__{resources: resources}, module), do: Map.get(resources, module)
end

defmodule AshRemote.Manifest.Resource do
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [
    :name,
    :module,
    :embedded?,
    :description,
    primary_key: [],
    fields: %{},
    relationships: %{},
    identities: %{},
    actions: [],
    validations: [],
    multitenancy: nil
  ]
end

defmodule AshRemote.Manifest.Validation do
  @moduledoc false
  # `opts` (and each where-condition's opts) is Elixir source for a literal
  # keyword list — see `AshRemote.Literal`.
  @type t :: %__MODULE__{}
  defstruct [:module, :opts, :message, on: [], where: [], only_when_valid?: false]
end

defmodule AshRemote.Manifest.Field do
  @moduledoc false
  @type kind :: :attribute | :calculation | :aggregate
  @type t :: %__MODULE__{}
  defstruct [
    :name,
    :kind,
    :type,
    :aggregate_kind,
    :description,
    allow_nil?: true,
    writable?: false,
    has_default?: false,
    filterable?: false,
    sortable?: false,
    primary_key?: false,
    sensitive?: false,
    select_by_default?: true,
    expression: nil,
    # Reproducible-aggregate metadata (populated only for aggregate fields whose
    # relationship + optional filter can be mirrored on the client). When
    # `relationship` is set the generator emits a NATIVE aggregate; otherwise the
    # aggregate is proxied as a `remote(...)` calc like any other opaque field.
    relationship: nil,
    aggregate_field: nil,
    aggregate_filter: nil,
    arguments: [],
    filter_operators: [],
    filter_functions: []
  ]
end

defmodule AshRemote.Manifest.Type do
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [:kind, :name, :module, :values, :constraints, :item_type, :instance_of]
end

defmodule AshRemote.Manifest.Relationship do
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [
    :name,
    :type,
    :cardinality,
    :destination,
    :description,
    :source_attribute,
    :destination_attribute,
    allow_nil?: true
  ]
end

defmodule AshRemote.Manifest.Action do
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [
    :name,
    :type,
    :returns,
    :pagination,
    primary?: false,
    get?: false,
    inputs: []
  ]
end

defmodule AshRemote.Manifest.Argument do
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [:name, :type, allow_nil?: true, has_default?: false, required?: false]
end
