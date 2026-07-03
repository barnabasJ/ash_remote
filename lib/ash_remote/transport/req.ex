defmodule AshRemote.Transport.Req do
  @moduledoc """
  Default `AshRemote.Transport` implementation, backed by `Req`.

  The RPC protocol returns a `200` envelope for both success and application
  errors, so any decoded map is returned as `{:ok, body}`. Only genuine
  transport failures (connection refused, timeout, non-JSON) become `{:error, _}`.

  ## Debugging

  Set `config :ash_remote, debug_requests: true` to log every RPC request at
  `Logger` debug level — URL, resource/action, outcome, duration, and the
  request/response bodies:

      [debug] ash_remote: POST http://127.0.0.1:4010/rpc/run TodoServer.Todo.read → ok (4.2ms)
      request:  %{"action" => "read", ...}
      response: %{"data" => [...], "success" => true}

  The logging is attached as `Req` request/response/error steps, so it rides
  Req's own pipeline (after JSON decoding, once per delivered result).
  """
  @behaviour AshRemote.Transport

  require Logger

  alias AshRemote.Transport.Config

  @impl true
  def request(%Config{} = config, path, body) when path in [:run, :validate] do
    result =
      [
        method: :post,
        url: Config.url(config, path),
        json: body,
        headers: config.headers,
        receive_timeout: config.receive_timeout,
        retry: config.retry,
        decode_json: [keys: :strings]
      ]
      |> Req.new()
      |> attach_debug()
      |> Req.request()

    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  # --- debug logging (Req steps) --------------------------------------------

  defp attach_debug(req) do
    if Application.get_env(:ash_remote, :debug_requests, false) do
      req
      |> Req.Request.append_request_steps(
        ash_remote_debug:
          &Req.Request.put_private(&1, :ash_remote_started, System.monotonic_time())
      )
      |> Req.Request.append_response_steps(ash_remote_debug: &log_response/1)
      |> Req.Request.append_error_steps(ash_remote_debug: &log_error/1)
    else
      req
    end
  end

  defp log_response({request, response}) do
    log(request, outcome(response), response.body)
    {request, response}
  end

  defp log_error({request, exception}) do
    log(request, "transport error: #{inspect(exception)}", exception)
    {request, exception}
  end

  defp log(request, outcome, response_payload) do
    body = request.options[:json]

    Logger.debug(fn ->
      """
      ash_remote: POST #{URI.to_string(request.url)} #{body["resource"]}.#{body["action"]} → #{outcome} (#{elapsed_ms(request)}ms)
      request:  #{inspect(body, pretty: true)}
      response: #{inspect(response_payload, pretty: true)}\
      """
    end)
  end

  defp outcome(%Req.Response{status: status, body: body}) when status in 200..299 do
    case body do
      %{"success" => false} -> "error"
      _ -> "ok"
    end
  end

  defp outcome(%Req.Response{status: status}), do: "http #{status}"

  defp elapsed_ms(request) do
    case Req.Request.get_private(request, :ash_remote_started) do
      nil ->
        "?"

      started ->
        elapsed = System.monotonic_time() - started
        System.convert_time_unit(elapsed, :native, :microsecond) / 1000
    end
  end
end
