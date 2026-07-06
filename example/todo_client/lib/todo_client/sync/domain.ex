defmodule TodoClient.Sync do
  @moduledoc """
  The app-owned sync-state domain: it holds the LocalOutbox outbox-entry
  resource (the durable, ordered replication queue). Keeping it an ordinary Ash
  domain lets the app attach policies/notifiers and query outbox state directly.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(TodoClient.Sync.OutboxEntry)
  end
end
