# Used by "mix format"
locals_without_parens = [
  # `remote do ... end` section options (AshRemote.DataLayer / AshRemote.Resource.Section).
  source: 1,
  base_url: 1,
  action_map: 1,
  realtime?: 1,
  schema_version: 1,
  source_hash: 1,
  # ash_multi_datalayer's `multi_data_layer do ... end` DSL. That package
  # doesn't export its own `locals_without_parens` yet, so declare them here
  # too (exported below for anything that `import_deps: [:ash_remote]`).
  layer: 2,
  read_order: 1,
  write_order: 1,
  orchestrator: 1
]

[
  import_deps: [:ash],
  plugins: [Spark.Formatter],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  subdirectories: ["packages/*"]
]
