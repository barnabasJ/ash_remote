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
  """

  @doc "The `:persistent_term` key for a base_url."
  def key(base_url), do: {__MODULE__, normalize(base_url)}

  @doc "Generate, store, and return a fresh client id for `base_url`."
  def register(base_url) do
    id = Ash.UUID.generate()
    put(base_url, id)
    id
  end

  @doc "Store an explicit client id for `base_url`."
  def put(base_url, id), do: :persistent_term.put(key(base_url), id)

  @doc "The client id registered for `base_url`, or `nil`."
  def get(base_url), do: :persistent_term.get(key(base_url), nil)

  @doc "Remove any client id registered for `base_url`."
  def delete(base_url), do: :persistent_term.erase(key(base_url))

  defp normalize(base_url) when is_binary(base_url), do: String.trim_trailing(base_url, "/")
end
