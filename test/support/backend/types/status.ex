defmodule AshRemote.Backend.Todo.Status do
  @moduledoc "Enum type exercised by the manifest/codegen (named type)."
  use Ash.Type.Enum, values: [:pending, :doing, :done]
end
