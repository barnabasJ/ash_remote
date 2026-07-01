defmodule AshRemote.Resource.Info do
  @moduledoc "Introspection for the `AshRemote.Resource` extension."
  use Spark.InfoGenerator, extension: AshRemote.Resource, sections: [:remote]

  @doc "Whether a resource uses the `AshRemote.Resource` extension."
  def remote?(resource) do
    AshRemote.Resource in Spark.extensions(resource)
  end
end
