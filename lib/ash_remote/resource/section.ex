defmodule AshRemote.Resource.Section do
  @moduledoc false

  # `AshRemote.DataLayer` folds this section in directly (like
  # `AshSqlite.DataLayer` does for its `sqlite do ... end` block) so
  # `data_layer: AshRemote.DataLayer` alone is enough — Spark treats
  # `data_layer:` as an implicit extension slot, no separate `extensions:`
  # entry needed. When `AshRemote.DataLayer` is instead nested inside some
  # other top-level data layer (e.g. `layer(:remote, AshRemote.DataLayer)`
  # under `AshMultiDatalayer.DataLayer`), list it explicitly under
  # `extensions: [AshRemote.DataLayer]` — Spark only auto-attaches sections
  # for the module named as the resource's own `data_layer:`.

  def remote do
    %Spark.Dsl.Section{
      name: :remote,
      describe: "Configuration for reaching the remote backend for this resource.",
      schema: [
        source: [
          type: :string,
          required: true,
          doc: "The backend resource's manifest module string (the wire `resource`)."
        ],
        base_url: [
          type: :string,
          required: false,
          doc: "Optional base URL override; falls back to `config :ash_remote, :base_url`."
        ],
        action_map: [
          type: :keyword_list,
          default: [],
          doc: "Client action name → backend action name overrides (defaults to identity)."
        ],
        realtime?: [
          type: :boolean,
          default: false,
          doc:
            "Subscribe to server-pushed realtime notifications for this resource. " <>
              "`AshRemote.Realtime` auto-joins a channel topic per realtime resource and " <>
              "re-emits a local Ash notification for each broadcast."
        ],
        schema_version: [
          type: :string,
          required: false,
          doc: "The manifest schema_version this resource was generated from."
        ],
        source_hash: [
          type: :string,
          required: false,
          doc: "A hash of the source manifest resource, for regeneration bookkeeping."
        ]
      ]
    }
  end
end
