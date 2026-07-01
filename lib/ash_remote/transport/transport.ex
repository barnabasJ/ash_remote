defmodule AshRemote.Transport do
  @moduledoc """
  Behaviour for RPC transports.

  A transport is responsible only for moving a request body to the backend and
  returning the decoded JSON response map. Protocol semantics (building request
  bodies, parsing responses) live in `AshRemote.Protocol`.
  """

  @type config :: AshRemote.Transport.Config.t()
  @type body :: map()

  @doc """
  Send `body` (a JSON-encodable map) to `path` (`:run` or `:validate`) using the
  given config. Returns the decoded response map or an error.
  """
  @callback request(config(), path :: :run | :validate, body()) ::
              {:ok, map()} | {:error, term()}
end

defmodule AshRemote.Transport.Config do
  @moduledoc "Resolved transport configuration for a single call."

  @type t :: %__MODULE__{
          module: module(),
          base_url: String.t(),
          run_path: String.t(),
          validate_path: String.t(),
          headers: [{String.t(), String.t()}],
          receive_timeout: pos_integer(),
          retry: term()
        }

  defstruct module: AshRemote.Transport.Req,
            base_url: nil,
            run_path: "/rpc/run",
            validate_path: "/rpc/validate",
            headers: [],
            receive_timeout: 15_000,
            retry: false

  @doc "Build a config from a keyword list or map, filling defaults."
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)
  def new(opts) when is_map(opts), do: struct!(__MODULE__, Map.to_list(opts))

  @doc "The absolute URL for a given logical path."
  def url(%__MODULE__{base_url: base} = config, :run), do: join(base, config.run_path)
  def url(%__MODULE__{base_url: base} = config, :validate), do: join(base, config.validate_path)

  defp join(base, path) do
    String.trim_trailing(base, "/") <> "/" <> String.trim_leading(path, "/")
  end
end
