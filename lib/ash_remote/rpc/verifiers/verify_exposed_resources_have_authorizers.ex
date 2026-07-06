defmodule AshRemote.Rpc.Verifiers.VerifyExposedResourcesHaveAuthorizers do
  @moduledoc """
  R-4: warns (never errors — a bare demo/prototype with no authorization is a
  legitimate choice) when an `expose`d resource has no authorizers. `run_action`
  runs exactly Ash's normal authorization posture — correct — but a resource
  with zero authorizers is an unauthenticated open door with no signal that
  anything is missing. This verifier is that signal.
  """
  use Spark.Dsl.Verifier

  alias AshRemote.Rpc.Info

  @impl true
  def verify(dsl) do
    module = Spark.Dsl.Verifier.get_persisted(dsl, :module)

    dsl
    |> Info.rpc()
    |> Enum.each(&maybe_warn(&1, module))

    :ok
  end

  defp maybe_warn(entry, domain) do
    if entry.expose != [] and Ash.Resource.Info.authorizers(entry.resource) == [] do
      IO.warn(
        "#{inspect(entry.resource)} is exposed over RPC (by #{inspect(domain)}) but has no " <>
          "authorizers — every exposed action is reachable by anyone who can reach this " <>
          "server, unauthenticated. If this is intentional (a demo/prototype), you can " <>
          "ignore this warning; otherwise add `authorizers: [Ash.Policy.Authorizer]` (or " <>
          "another authorizer) and policies to the resource.",
        []
      )
    end
  end
end
