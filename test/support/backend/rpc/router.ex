defmodule AshRemote.Backend.Rpc.Router do
  @moduledoc """
  Ported (template) Plug router mounting the RPC endpoints for the reference backend.
  Mirrors the trivial `ash_typescript` controller: decode params, run, JSON-encode.
  """
  use Plug.Router

  alias AshRemote.Backend.Rpc.Server

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :match
  plug :dispatch

  post "/rpc/run" do
    send_json(conn, Server.rescue_run(conn.params))
  end

  post "/rpc/validate" do
    send_json(conn, Server.rescue_validate(conn.params))
  end

  match _ do
    send_json(conn, %{"success" => false, "errors" => [%{"type" => "not_found"}]}, 404)
  end

  defp send_json(conn, body, status \\ 200) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
