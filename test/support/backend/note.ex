defmodule AshRemote.Backend.Note do
  @moduledoc """
  A context-multitenant resource — R-1's regression fixture. Two tenants must
  never see each other's rows over RPC, and the server must apply the WIRE
  tenant (there's no upstream auth plug in the test harness setting a conn
  tenant, so this proves the tenant is genuinely carried on the protocol body,
  not merely tolerated when a conn happens to already have one).
  """
  use Ash.Resource,
    domain: AshRemote.Backend.Domain,
    data_layer: Ash.DataLayer.Ets,
    notifiers: [AshRemote.Server.Notifier]

  ets do
    private?(false)
  end

  multitenancy do
    strategy(:context)
    # global?: true only so the test harness's untenanted `reset!/0` sweep
    # (`Ash.read!(resource)` with no tenant, run for every backend resource)
    # can see and clean up rows across tenants — every assertion in the R-1
    # regression test itself always passes an explicit tenant.
    global?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:text, :string, public?: true, allow_nil?: false)
  end

  validations do
    # Echoes the changeset's tenant back as a validation error naming it —
    # the B0 validate-path test's probe for "did the wire tenant actually
    # reach `Ash.Changeset.for_create` inside `Server.validate_action`,
    # independently of `/rpc/run`" (R-1). Gated on a magic input value so it
    # never interferes with ordinary creates/updates.
    validate({AshRemote.Backend.Note.EchoTenant, []})
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshRemote.Backend.Note.EchoTenant do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :text) == "__echo_tenant__" do
      {:error, field: :text, message: "tenant=#{inspect(changeset.tenant)}"}
    else
      :ok
    end
  end
end
