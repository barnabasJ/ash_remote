defmodule AshRemote.Resource do
  @moduledoc """
  Ash resource extension for remote (RPC-backed) resources.

  Adds a `remote do ... end` section describing how to reach the backend:

      remote do
        source "MyApp.Todo"           # the backend resource's manifest module string
        action_map read: :list_todos  # optional client→backend action-name overrides
        schema_version "1.0.0"
        source_hash "abc123"
      end

  `base_url` is intentionally resolved lazily at call time (from this block if
  set, else `config :ash_remote, :base_url`) so one generated codebase works
  across environments.
  """

  @remote %Spark.Dsl.Section{
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
      schema_version: [
        type: :string,
        required: false,
        doc: "The manifest schema_version this resource was generated from."
      ],
      source_hash: [
        type: :string,
        required: false,
        doc: "A hash of the source manifest resource, for regeneration bookkeeping."
      ],
      managed_attributes: [type: {:list, :atom}, default: [], doc: "Generator-owned attributes."],
      managed_relationships: [
        type: {:list, :atom},
        default: [],
        doc: "Generator-owned relationships."
      ],
      managed_calculations: [
        type: {:list, :atom},
        default: [],
        doc: "Generator-owned calculations."
      ],
      managed_aggregates: [type: {:list, :atom}, default: [], doc: "Generator-owned aggregates."],
      managed_actions: [type: {:list, :atom}, default: [], doc: "Generator-owned actions."]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@remote],
    verifiers: [AshRemote.Resource.Verifiers.ValidateRemote]
end
