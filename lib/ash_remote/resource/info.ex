defmodule AshRemote.Resource.Info do
  @moduledoc "Introspection for the `remote do ... end` section (`AshRemote.DataLayer`)."
  use Spark.InfoGenerator, extension: AshRemote.DataLayer, sections: [:remote]

  @doc """
  Whether a resource actually declared a `remote do ... end` block (checked by
  the presence of its required `source` option, not just extension
  membership: `AshRemote.DataLayer` folds the `:remote` section in for EVERY
  resource that uses it as `data_layer:`, including hand-written resources
  that configure `remote_config` via application env instead of the DSL — so
  extension presence alone can't distinguish the two).
  """
  def remote?(resource) do
    match?({:ok, _}, remote_source(resource))
  end
end
