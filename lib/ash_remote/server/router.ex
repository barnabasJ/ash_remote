defmodule AshRemote.Server.Router do
  @moduledoc """
  A ready-to-mount Plug router for the RPC protocol. A backend needs no custom
  RPC code — just its resources and:

      defmodule MyApp.RpcRouter do
        use AshRemote.Server.Router, otp_app: :my_app
      end

      # then, e.g. under Bandit:
      {Bandit, plug: MyApp.RpcRouter, port: 4000}

  Serves:

    * `POST /rpc/run`       — run an action
    * `POST /rpc/validate`  — validate action input
    * `GET  /manifest.json` — the published `Ash.Info.Manifest`
    * `GET  /health`        — liveness check

  The exposed surface is every public action of the OTP app's Ash domains (the
  same set the published manifest describes). `Plug` is referenced only inside
  the macro expansion, so only the backend using this router needs `plug` —
  `ash_remote` clients do not.
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    quote do
      use Plug.Router

      @ash_remote_otp_app unquote(otp_app)

      plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
      plug :match
      plug :dispatch

      post "/rpc/run" do
        ash_remote_send_json(
          var!(conn),
          AshRemote.Server.run_action(@ash_remote_otp_app, var!(conn).params)
        )
      end

      post "/rpc/validate" do
        ash_remote_send_json(
          var!(conn),
          AshRemote.Server.validate_action(@ash_remote_otp_app, var!(conn).params)
        )
      end

      get "/manifest.json" do
        var!(conn)
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, AshRemote.Server.manifest_json(@ash_remote_otp_app))
      end

      get "/health", do: Plug.Conn.send_resp(var!(conn), 200, "ok")

      match _ do
        ash_remote_send_json(
          var!(conn),
          %{"success" => false, "errors" => [%{"type" => "not_found"}]},
          404
        )
      end

      defp ash_remote_send_json(conn, body, status \\ 200) do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end
    end
  end
end
