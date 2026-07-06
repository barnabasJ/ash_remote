defmodule AshRemote.Test.MultiDatalayer.Resources do
  @moduledoc """
  Canonical test resources for the `AshRemote.MultiDatalayer.*` utilities.

  `CachedThing` reuses `Ash.DataLayer.Ets` for BOTH the `:cache` and `:remote`
  layer slots. This is deliberate: the invalidation logic under test only
  point-queries/mutates the resolved `:cache` layer and the in-memory coverage
  ledger — it never dispatches to the "remote" layer — so two layers resolving
  to the same physical Ets store don't interfere, and no live server/database is
  needed. It runs the default ProvenCoverage orchestrator.

  `SpyThing` is a multi-datalayer resource whose orchestrator is
  `AshRemote.Test.MultiDatalayer.SpyOrchestrator` — a distinct strategy that
  reports its inbound reactions — used to prove the utilities are
  strategy-agnostic (they dispatch to whatever orchestrator the resource
  declares, standing in for LocalOutbox without its SQLite/Oban stack).
  """

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshRemote.Test.MultiDatalayer.Resources.CachedThing)
      resource(AshRemote.Test.MultiDatalayer.Resources.PlainEtsThing)
      resource(AshRemote.Test.MultiDatalayer.Resources.SpyThing)
    end
  end

  defmodule CachedThing do
    @moduledoc "A multi-datalayer ash_remote client on ProvenCoverage — invalidates on notification, drops on gap."

    use Ash.Resource,
      domain: Domain,
      data_layer: AshMultiDatalayer.DataLayer,
      extensions: [AshRemote.Resource],
      notifiers: [AshRemote.MultiDatalayer.ChangeNotifier]

    multi_data_layer do
      layer(:cache, Ash.DataLayer.Ets)
      layer(:remote, Ash.DataLayer.Ets)

      read_order([:cache, :remote])
      write_order([:remote, :cache])
    end

    remote do
      source("Test.CachedThing")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)

      attribute :status, :atom do
        public?(true)
        constraints(one_of: [:open, :done])
        default(:open)
      end
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule SpyThing do
    @moduledoc "A multi-datalayer resource on a spy (non-ProvenCoverage) orchestrator — proves strategy-agnostic dispatch."

    use Ash.Resource,
      domain: Domain,
      data_layer: AshMultiDatalayer.DataLayer,
      notifiers: [AshRemote.MultiDatalayer.ChangeNotifier]

    multi_data_layer do
      orchestrator(AshRemote.Test.MultiDatalayer.SpyOrchestrator)

      layer(:cache, Ash.DataLayer.Ets)
      layer(:remote, Ash.DataLayer.Ets)

      read_order([:cache, :remote])
      write_order([:remote, :cache])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule PlainEtsThing do
    @moduledoc "A plain Ets resource, no multi-datalayer at all — for ordered?/1 negative cases."

    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end
end

defmodule AshRemote.Test.MultiDatalayer.Notifications do
  @moduledoc """
  Builds fabricated `%Ash.Notifier.Notification{}` structs mirroring the shape
  `AshRemote.Realtime.Inbound.notify/3` constructs for a realtime-replicated
  change, so the change notifier can be tested without a live server/websocket.
  """

  alias Ash.Resource.Info, as: ResourceInfo

  @doc "Builds a notification for `action_name` (:create/:update/:destroy) carrying `data` as the record."
  def build(resource, action_name, data, opts \\ []) do
    domain = ResourceInfo.domain(resource)
    action = ResourceInfo.action(resource, action_name)
    tenant = Keyword.get(opts, :tenant)

    changeset = %Ash.Changeset{
      resource: resource,
      domain: domain,
      action: action,
      action_type: action.type,
      data: data,
      attributes: %{},
      tenant: tenant,
      to_tenant: tenant,
      context: %{ash_remote: %{origin: :remote}},
      valid?: true
    }

    %Ash.Notifier.Notification{
      resource: resource,
      domain: domain,
      action: action,
      data: data,
      changeset: changeset,
      actor: nil,
      metadata: %{}
    }
  end
end
