defprotocol AshRemote.Server.ErrorFormatter do
  @moduledoc """
  Extensibility hook for `AshRemote.Server`'s wire error encoding, mirroring
  `AshTypescript.Rpc.Error` — a consuming app defines a `defimpl` for a
  domain-specific Ash exception struct (e.g. a Splode-based validation error
  with its own `:type`) to control exactly what `"type"`/`"message"` the wire
  payload carries for it, instead of falling through to the generic
  `Exception.message/1`-based derivation `AshRemote.Server` uses by default.

  That generic default is deliberately conservative: for anything other than
  `:invalid`/`:forbidden`-class errors it logs the real exception server-side
  and returns a correlation id instead of echoing potentially-sensitive
  exception internals to the caller (see `AshRemote.Server`'s `@safe_classes`
  doc). It's also at the mercy of whatever `Exception.message/1` a struct
  happens to implement — some libraries (see `AshScheduling.ScheduleError`,
  whose `humanize/2` is an upstream stub that unconditionally returns `"Not
  implemented yet"`) don't yet implement anything useful there. This protocol
  lets an app override the message (and optionally the wire `"type"` string)
  for exactly the structs it cares about, without touching `AshRemote.Server`
  itself or relaxing what the generic path is willing to expose for
  everything else.

  ## Example

      defimpl AshRemote.Server.ErrorFormatter, for: MyApp.SomeDomainError do
        def format(%{reason: reason}), do: %{message: humanize(reason)}
      end
  """

  @fallback_to_any true

  @doc """
  Return `%{message: String.t()}` (optionally with a `:type` key overriding
  the default wire type string) to use for this error, or `nil` to fall back
  to `AshRemote.Server`'s own type/message derivation.
  """
  @spec format(t()) :: %{required(:message) => String.t(), optional(:type) => String.t()} | nil
  def format(error)
end

defimpl AshRemote.Server.ErrorFormatter, for: Any do
  def format(_error), do: nil
end
