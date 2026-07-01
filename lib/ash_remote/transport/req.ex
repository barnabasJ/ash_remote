defmodule AshRemote.Transport.Req do
  @moduledoc """
  Default `AshRemote.Transport` implementation, backed by `Req`.

  The RPC protocol returns a `200` envelope for both success and application
  errors, so any decoded map is returned as `{:ok, body}`. Only genuine
  transport failures (connection refused, timeout, non-JSON) become `{:error, _}`.
  """
  @behaviour AshRemote.Transport

  alias AshRemote.Transport.Config

  @impl true
  def request(%Config{} = config, path, body) when path in [:run, :validate] do
    url = Config.url(config, path)

    result =
      Req.post(url,
        json: body,
        headers: config.headers,
        receive_timeout: config.receive_timeout,
        retry: config.retry,
        decode_json: [keys: :strings]
      )

    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end
end
