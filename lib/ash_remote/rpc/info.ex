defmodule AshRemote.Rpc.Info do
  @moduledoc "Introspection for the `AshRemote.Rpc` domain extension."
  use Spark.InfoGenerator, extension: AshRemote.Rpc, sections: [:rpc]

  @doc "Whether a domain uses the `AshRemote.Rpc` extension."
  def rpc?(domain), do: AshRemote.Rpc in Spark.extensions(domain)

  @doc "The realtime `pub_sub` module declared by a domain, or `nil` if none."
  def pub_sub(domain) do
    case rpc_pub_sub(domain) do
      {:ok, module} -> module
      _ -> nil
    end
  end

  @doc "The exposed `{resource, action}` entrypoints declared by a domain."
  def entrypoints(domain) do
    for %{resource: resource, expose: exposed} <- rpc(domain), %{action: action} <- exposed do
      {resource, action}
    end
  end

  @doc """
  The realtime-published `{resource, action}` pairs declared by a domain:
  `(exposed ∪ publish) ∖ no_publish` per resource. Opt-out (`no_publish`) always
  wins. Mutation-type filtering is applied downstream (in the notifier), where
  the action struct is at hand.
  """
  def publications(domain) do
    for entry <- rpc(domain), action <- entry_publications(entry) do
      {entry.resource, action}
    end
  end

  @doc "Whether `{resource, action}` is realtime-published by a domain."
  def publication?(domain, resource, action) do
    Enum.any?(rpc(domain), fn entry ->
      entry.resource == resource and action in entry_publications(entry)
    end)
  end

  defp entry_publications(entry) do
    exposed = Enum.map(entry.expose, & &1.action)
    published = Enum.map(entry.publish, & &1.action)
    opted_out = Enum.map(entry.no_publish, & &1.action)

    ((exposed ++ published) |> Enum.uniq()) -- opted_out
  end
end
