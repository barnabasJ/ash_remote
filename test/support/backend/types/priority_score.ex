defmodule AshRemote.Backend.PriorityScore do
  @moduledoc "NewType exercised by the manifest/codegen (named type with constraints)."
  use Ash.Type.NewType, subtype_of: :integer, constraints: [min: 0, max: 100]
end
