defmodule AshRemote.Client.UpsertOnly do
  @moduledoc """
  Client mirror of `AshRemote.Backend.UpsertOnly` — the `server_upserts?`
  regression fixture, also covering `put_write_action/3`'s primary-action
  fallback (see the `create` action below). `remote do end` is DSL-configured
  (`source:` set for real, not the app-config-map fallback other client test
  fixtures use), so `remote_config/1` takes the branch that actually reads
  `server_upserts?`.
  """
  use Ash.Resource,
    domain: AshRemote.Client.Domain,
    data_layer: AshRemote.DataLayer

  remote do
    source "AshRemote.Backend.UpsertOnly"
    server_upserts?(true)
  end

  actions do
    default_accept [:id, :token, :title]

    read :by_token do
      argument :token, :string, allow_nil?: false
      prepare AshRemote.CaptureArguments
      filter expr(token == ^arg(:token))
    end

    # Deliberately NOT `primary?: true` — mirrors arcc-center's real
    # `Evv.Event.create`, which has exactly one create action and never
    # marked it primary (nothing about calling it by name needs that).
    # `put_write_action/3` must fall back to "the sole create action" rather
    # than hard-requiring `Ash.Resource.Info.primary_action!/2`.
    create :create
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :token, :string, public?: true, allow_nil?: false
    attribute :title, :string, public?: true, allow_nil?: false
  end
end
