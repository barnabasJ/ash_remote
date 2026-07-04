defmodule AshRemote.Realtime.Event do
  @moduledoc """
  A realtime lifecycle event, delivered to processes registered via
  `AshRemote.Realtime.listen_lifecycle/1` as `{AshRemote.Realtime, %Event{}}`.

  Types:

    * `:connected` — the socket connected (or reconnected).
    * `:disconnected` — the socket dropped; buffered events, if any, are lost.
    * `:resubscribed` — a topic was (re)joined after a gap. This is the documented
      "refetch now" signal: notifications are at-most-once with no replay, so a
      client that cares about missed events should refetch on `:resubscribed`.
    * `:join_denied` — the server refused a topic join (authorization/tenant).

  `resource` and `tenant` identify the subscription where applicable (`nil` for
  connection-wide events like `:connected`/`:disconnected`).
  """
  @type type :: :connected | :disconnected | :resubscribed | :join_denied

  @type t :: %__MODULE__{
          type: type,
          resource: module | nil,
          tenant: term,
          base_url: String.t() | nil,
          topic: String.t() | nil
        }

  defstruct [:type, :resource, :tenant, :base_url, :topic]
end
