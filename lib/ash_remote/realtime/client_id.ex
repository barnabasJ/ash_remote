defmodule AshRemote.Realtime.ClientId do
  @moduledoc """
  Per-`base_url` client correlation id, used to suppress echoes: the realtime
  `Connection` registers an id for its base_url, `AshRemote.Transport.Req`
  attaches it as the `x-ash-remote-client-id` header on RPC writes, the server
  stamps it into the changeset context, and the notifier echoes it back in
  `origin.client_id` — so the client can drop the broadcast copy of its own write.

  Stored in `:persistent_term` (read on every RPC request, written rarely — once
  per connection), keyed by the normalized base_url so the transport and the
  connection agree without threading a pid around.

  **Topology (R-10)**: one `AshRemote.Realtime` supervisor per base_url is the
  supported shape. `register/1` is idempotent — it keeps the FIRST id ever
  registered for a base_url rather than overwriting on every call — for two
  reasons: (1) `:persistent_term.put/2` on an EXISTING key triggers a full VM
  global GC pass (cost scales with total process count), so an unconditional
  overwrite on every supervisor restart is needlessly expensive; (2)
  overwriting would change the echo-correlation identity out from under any
  in-flight request still carrying the old id. A second connection process
  registering for the SAME base_url (a second `AshRemote.Realtime` supervisor
  pointed at one already-registered base_url, or an ordinary supervisor
  restart) therefore shares the existing identity by design — logged once so
  an operator notices if it was unintentional.
  """

  require Logger

  @doc "The `:persistent_term` key for a base_url."
  def key(base_url), do: {__MODULE__, normalize(base_url)}

  @doc """
  Idempotently ensure a client id exists for `base_url`, returning it — the
  FIRST id ever registered survives every subsequent call (see the topology
  note above), generating one only if none exists yet.
  """
  def register(base_url) do
    key = key(base_url)

    case :persistent_term.get(key, :unset) do
      :unset ->
        id = Ash.UUID.generate()
        :persistent_term.put(key, id)
        id

      existing ->
        Logger.info(
          "ash_remote: a connection re-registered for base_url #{inspect(base_url)}, which " <>
            "already has an echo-correlation id — reusing it (#{existing}). Expected on a " <>
            "supervisor restart; if this is a SECOND AshRemote.Realtime supervisor for the " <>
            "same base_url, note that it shares identity with the first by design."
        )

        existing
    end
  end

  @doc "Store an explicit client id for `base_url`."
  def put(base_url, id), do: :persistent_term.put(key(base_url), id)

  @doc "The client id registered for `base_url`, or `nil`."
  def get(base_url), do: :persistent_term.get(key(base_url), nil)

  @doc "Remove any client id registered for `base_url`."
  def delete(base_url), do: :persistent_term.erase(key(base_url))

  defp normalize(base_url) when is_binary(base_url), do: String.trim_trailing(base_url, "/")
end
