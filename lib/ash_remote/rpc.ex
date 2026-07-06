defmodule AshRemote.Rpc.Exposed do
  @moduledoc false
  defstruct [:action, :__spark_metadata__]
end

defmodule AshRemote.Rpc.Publish do
  @moduledoc false
  defstruct [:action, :__spark_metadata__]
end

defmodule AshRemote.Rpc.NoPublish do
  @moduledoc false
  defstruct [:action, :__spark_metadata__]
end

defmodule AshRemote.Rpc.ResourceEntry do
  @moduledoc false
  defstruct [:resource, :__spark_metadata__, expose: [], publish: [], no_publish: []]
end

defmodule AshRemote.Rpc do
  @moduledoc """
  Domain extension that declares which resource actions are exposed over RPC —
  the `ash_remote` counterpart to `ash_typescript`'s `typescript_rpc` block.

      defmodule MyApp.Domain do
        use Ash.Domain, extensions: [AshRemote.Rpc]

        rpc do
          pub_sub MyAppWeb.Endpoint

          resource MyApp.Todo do
            expose :read
            expose :create
            expose :update
            expose :destroy
            publish :internal_touch   # opt an unexposed action IN to realtime
            no_publish :create        # opt an exposed action OUT (always wins)
          end

          resource MyApp.User do
            expose :read
          end
        end
      end

  The RPC server (`AshRemote.Server`) only runs exposed `{resource, action}`
  pairs, and the published manifest describes exactly this surface. Actions are
  addressed on the wire by `{resource, action}`, so no per-action RPC name is
  needed.

  **Exposure ⇏ authorization (R-4).** `expose`ing an action makes it reachable
  by anyone who can reach this server — `Server.run_action`/`validate_action`
  apply exactly Ash's normal authorization posture, which for a resource with
  NO authorizers is: everything is allowed. A compile-time verifier warns
  (never errors — a bare demo/prototype with no authorization is a legitimate
  choice) when an exposed resource has no authorizers, but it is still on you
  to add `authorizers: [Ash.Policy.Authorizer]` (or another authorizer) and
  policies to any resource that shouldn't be a fully open door.

  ## Realtime publications

  When a resource attaches `AshRemote.Server.Notifier`, its mutation actions are
  broadcast to subscribed clients. The published set is
  `(exposed ∪ publish) ∖ no_publish` — exposing an action publishes it by
  default, `publish` opts an otherwise-unexposed action in, and `no_publish`
  always wins. `pub_sub` names the module (e.g. a `Phoenix.Endpoint`) the
  notifier broadcasts through.
  """

  @expose %Spark.Dsl.Entity{
    name: :expose,
    describe: "Expose a resource action over RPC.",
    target: AshRemote.Rpc.Exposed,
    args: [:action],
    schema: [action: [type: :atom, required: true, doc: "The action name to expose."]]
  }

  @publish %Spark.Dsl.Entity{
    name: :publish,
    describe: "Opt an action IN to realtime publication (even if it is not exposed).",
    target: AshRemote.Rpc.Publish,
    args: [:action],
    schema: [action: [type: :atom, required: true, doc: "The action name to publish."]]
  }

  @no_publish %Spark.Dsl.Entity{
    name: :no_publish,
    describe: "Opt an action OUT of realtime publication (always wins over expose/publish).",
    target: AshRemote.Rpc.NoPublish,
    args: [:action],
    schema: [action: [type: :atom, required: true, doc: "The action name to never publish."]]
  }

  @resource %Spark.Dsl.Entity{
    name: :resource,
    describe: "Declare the exposed actions for a resource.",
    target: AshRemote.Rpc.ResourceEntry,
    args: [:resource],
    entities: [expose: [@expose], publish: [@publish], no_publish: [@no_publish]],
    schema: [
      resource: [type: {:spark, Ash.Resource}, required: true, doc: "The resource being exposed."]
    ]
  }

  @rpc %Spark.Dsl.Section{
    name: :rpc,
    describe: "Declare the RPC-exposed surface of this domain.",
    schema: [
      pub_sub: [
        type: :atom,
        required: false,
        doc:
          "A module exporting `broadcast/3` (e.g. a `Phoenix.Endpoint`) that " <>
            "`AshRemote.Server.Notifier` publishes realtime notifications through."
      ]
    ],
    no_depend_modules: [:pub_sub],
    entities: [@resource]
  }

  use Spark.Dsl.Extension,
    sections: [@rpc],
    verifiers: [
      AshRemote.Rpc.Verifiers.ValidatePublish,
      AshRemote.Rpc.Verifiers.VerifyExposedResourcesHaveAuthorizers
    ]
end
