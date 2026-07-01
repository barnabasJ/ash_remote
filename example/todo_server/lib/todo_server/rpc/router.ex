defmodule TodoServer.Rpc.Router do
  @moduledoc "HTTP endpoints: the RPC protocol plus the published manifest."
  use Plug.Router

  alias TodoServer.Rpc.{Manifest, Server}

  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :match
  plug :dispatch

  post "/rpc/run", do: send_json(conn, Server.rescue_run(conn.params))
  post "/rpc/validate", do: send_json(conn, Server.rescue_validate(conn.params))

  get "/manifest.json" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Manifest.to_json())
  end

  get "/health", do: send_resp(conn, 200, "ok")

  match _, do: send_json(conn, %{"success" => false, "errors" => [%{"type" => "not_found"}]}, 404)

  defp send_json(conn, body, status \\ 200) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
