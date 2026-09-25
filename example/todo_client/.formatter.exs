# Used by "mix format"
[
  import_deps: [:ash, :ash_remote, :ash_sqlite],
  plugins: [Spark.Formatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
