defmodule AshRemote.Server.ResourceResolver do
  @moduledoc """
  Resolves a client-supplied resource string against a precomputed
  string→module map — never `Module.concat/1` on untrusted input (R-2): every
  distinct string passed to `Module.concat/1` interns a new atom, and both
  `AshRemote.Server.resolve_resource/2` and
  `AshRemote.Server.Channel.resolve_resource/2` did that BEFORE checking
  membership, reachable pre-auth from the wire — an attacker sending
  arbitrarily many distinct garbage strings could exhaust the atom table.

  `AshRemote.Server` and `AshRemote.Server.Channel` check two DIFFERENT sets
  (all exposed resources vs. the published-for-realtime subset), so each site
  gets its own cached map, keyed by `{otp_app, site}` — a resolver for one
  site can never overwrite or accidentally reuse the other's map.
  """

  @doc """
  The module matching `resource_string` in `resources`, or `:error`. Caches
  the string→module map for `{otp_app, site}` in `:persistent_term` (bounded:
  one map per otp_app per site, written once per resource-set generation).
  """
  @spec resolve(atom(), :rpc | :channel, [module()], String.t()) :: {:ok, module()} | :error
  def resolve(otp_app, site, resources, resource_string) when is_binary(resource_string) do
    Map.fetch(map(otp_app, site, resources), resource_string)
  end

  def resolve(_otp_app, _site, _resources, _resource_string), do: :error

  defp map(otp_app, site, resources) do
    key = {__MODULE__, otp_app, site}

    case :persistent_term.get(key, :unset) do
      :unset ->
        built = Map.new(resources, &{inspect(&1), &1})
        :persistent_term.put(key, built)
        built

      built ->
        built
    end
  end
end
