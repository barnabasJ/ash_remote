defmodule AshRemote.Rpc.Exposed do
  @moduledoc false
  defstruct [:action, :__spark_metadata__]
end

defmodule AshRemote.Rpc.ResourceEntry do
  @moduledoc false
  defstruct [:resource, :__spark_metadata__, expose: []]
end

defmodule AshRemote.Rpc do
  @moduledoc """
  Domain extension that declares which resource actions are exposed over RPC —
  the `ash_remote` counterpart to `ash_typescript`'s `typescript_rpc` block.

      defmodule MyApp.Domain do
        use Ash.Domain, extensions: [AshRemote.Rpc]

        rpc do
          resource MyApp.Todo do
            expose :read
            expose :create
            expose :update
            expose :destroy
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
  """

  @expose %Spark.Dsl.Entity{
    name: :expose,
    describe: "Expose a resource action over RPC.",
    target: AshRemote.Rpc.Exposed,
    args: [:action],
    schema: [action: [type: :atom, required: true, doc: "The action name to expose."]]
  }

  @resource %Spark.Dsl.Entity{
    name: :resource,
    describe: "Declare the exposed actions for a resource.",
    target: AshRemote.Rpc.ResourceEntry,
    args: [:resource],
    entities: [expose: [@expose]],
    schema: [
      resource: [type: {:spark, Ash.Resource}, required: true, doc: "The resource being exposed."]
    ]
  }

  @rpc %Spark.Dsl.Section{
    name: :rpc,
    describe: "Declare the RPC-exposed surface of this domain.",
    entities: [@resource]
  }

  use Spark.Dsl.Extension, sections: [@rpc]
end
