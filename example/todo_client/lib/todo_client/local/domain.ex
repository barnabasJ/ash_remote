defmodule TodoClient.Local do
  @moduledoc """
  The offline-first domain. `TodoClient.Local.Todo` is served entirely from a
  local SQLite authority (0 RPC reads) and replicated to the server through the
  outbox — the LocalOutbox counterpart to the online-first `TodoClient.Remote`
  domain (ETS-cache-over-remote). Both front the same `TodoServer.Todo`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(TodoClient.Local.Todo)
  end
end
