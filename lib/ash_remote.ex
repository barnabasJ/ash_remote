defmodule AshRemote do
  @moduledoc """
  An Elixir client for the `ash_typescript` RPC protocol.

  A backend publishes a versioned `Ash.Info.Manifest` JSON artifact describing its
  RPC-exposed resources, types, and actions; `mix ash_remote.gen` turns that into
  standalone Ash resources backed by `AshRemote.DataLayer`, which speaks `/rpc/run`
  and `/rpc/validate`.

  See `AshRemote.DataLayer`, `AshRemote.Server`, `AshRemote.Rpc`, and
  `Mix.Tasks.AshRemote.Gen`.
  """
end
