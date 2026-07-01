defmodule AshRemote.Rpc.Info do
  @moduledoc "Introspection for the `AshRemote.Rpc` domain extension."
  use Spark.InfoGenerator, extension: AshRemote.Rpc, sections: [:rpc]

  @doc "Whether a domain uses the `AshRemote.Rpc` extension."
  def rpc?(domain), do: AshRemote.Rpc in Spark.extensions(domain)

  @doc "The exposed `{resource, action}` entrypoints declared by a domain."
  def entrypoints(domain) do
    for %{resource: resource, expose: exposed} <- rpc(domain), %{action: action} <- exposed do
      {resource, action}
    end
  end
end
