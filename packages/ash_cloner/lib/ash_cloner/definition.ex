defmodule AshCloner.Definition do
  @moduledoc """
  One module the cloner manages: the contract between definition producers
  (a manifest generator, `AshCloner.SourceCloner`, hand-built fixtures) and
  the apply engine (`AshCloner.apply_definitions/3`).

    * `module` — the target module name, as a string (already re-namespaced)
    * `kind` — `:resource` and `:domain` get entity-level reconciliation;
      `:verbatim` (and any other kind, e.g. `:type`) is created whole once
      and never touched again
    * `source` — complete module source, written as-is when the module
      doesn't exist yet
    * `entities` — `:resource` only: per-section `{name, code}` snippets
      (`%{attributes | relationships | validations | calculations |
      aggregates | actions => [{name, code}]}`), the unit of non-destructive
      regeneration
    * `resources` — `:domain` only: module strings the domain must reference
  """

  @type kind :: :resource | :domain | :verbatim | atom()
  @type entity :: {name :: atom() | String.t(), code :: String.t()}
  @type t :: %__MODULE__{
          module: String.t(),
          kind: kind(),
          source: String.t(),
          entities: %{optional(atom()) => [entity()]},
          resources: [String.t()]
        }

  defstruct [:module, :kind, :source, entities: %{}, resources: []]

  @doc "Build a definition from a map or keyword list of fields."
  @spec new(Enumerable.t()) :: t()
  def new(fields), do: struct!(__MODULE__, fields)
end
