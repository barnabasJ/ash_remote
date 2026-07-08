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

  The exposed surface is whatever the app's domains declare via the `AshRemote.Rpc`
  extension (`rpc do resource … expose :action end end`) — the same set the published
  manifest describes. `Plug` is referenced only inside the macro expansion, so only the
  backend using this router needs `plug` — `ash_remote` clients do not.

  **Exposure is not authorization (R-4)**: this router runs every exposed
  action with Ash's normal authorization posture, which for a resource with no
  authorizers means unauthenticated access. See `AshRemote.Rpc`'s moduledoc.

  ## `GET /manifest.json` is unauthenticated by default (L13)

  The published manifest (resource/action/attribute/relationship/calculation/
  aggregate names and their types — schema, not data) is served with no
  authentication check unless you opt in. This is an **explicit, accepted
  default**, not an oversight: the manifest describes the API's *shape*, the
  same information `AshRemote.Rpc`'s `expose`d actions already imply is
  reachable (an actor still needs to satisfy each action's own policies to
  actually read/write anything), and most deployments intentionally publish
  this the same way a GraphQL schema or OpenAPI spec is published for client
  generation. If your application's threat model treats the schema itself as
  sensitive (e.g. internal field/relationship names you don't want
  discoverable pre-auth), gate it with `manifest_auth:`:

      use AshRemote.Server.Router, otp_app: :my_app, manifest_auth: MyApp.ManifestAuthPlug

  `manifest_auth` is any module Plug (implementing `init/1`/`call/2`, e.g. an
  API-key check or `Ash.PlugHelpers`-based actor check) run immediately
  before `/manifest.json` is served — the same mounting model as any other
  Plug pipeline. A plug that halts the connection (`Plug.Conn.halt/1`) stops
  the manifest from being served, exactly like the rest of this router's Plug
  pipeline (`Plug.Router` never proceeds past a halted conn). `/rpc/run` and
  `/rpc/validate` are unaffected — they already run every exposed action
  through Ash's normal authorization, this option is scoped to the manifest
  route only.
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    {manifest_auth_module, manifest_auth_opts} =
      case Keyword.get(opts, :manifest_auth) do
        nil -> {nil, nil}
        {module, plug_opts} -> {module, plug_opts}
        module -> {module, []}
      end

    quote do
      use Plug.Router

      @ash_remote_otp_app unquote(otp_app)

      plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
      plug(:match)
      plug(:dispatch)

      post "/rpc/run" do
        ash_remote_send_json(
          var!(conn),
          AshRemote.Server.run_action(
            @ash_remote_otp_app,
            var!(conn).params,
            ash_remote_request_opts(var!(conn))
          )
        )
      end

      post "/rpc/validate" do
        ash_remote_send_json(
          var!(conn),
          AshRemote.Server.validate_action(
            @ash_remote_otp_app,
            var!(conn).params,
            ash_remote_request_opts(var!(conn))
          )
        )
      end

      get "/manifest.json" do
        conn = ash_remote_run_manifest_auth(var!(conn))

        if conn.halted do
          conn
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, AshRemote.Server.manifest_json(@ash_remote_otp_app))
        end
      end

      get("/health", do: Plug.Conn.send_resp(var!(conn), 200, "ok"))

      match _ do
        ash_remote_send_json(
          var!(conn),
          %{"success" => false, "errors" => [%{"type" => "not_found"}]},
          404
        )
      end

      # Resolve the actor/tenant/context from the conn — set by an upstream auth
      # plug (e.g. ash_authentication) via `Ash.PlugHelpers` — plus the realtime
      # echo-correlation id. Threaded into every RPC action so authorization and
      # multitenancy apply exactly as they would for a local call.
      defp ash_remote_request_opts(conn) do
        [
          actor: Ash.PlugHelpers.get_actor(conn),
          tenant: Ash.PlugHelpers.get_tenant(conn),
          context: Ash.PlugHelpers.get_context(conn),
          client_id: conn |> Plug.Conn.get_req_header("x-ash-remote-client-id") |> List.first()
        ]
      end

      defp ash_remote_send_json(conn, body, status \\ 200) do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end

      # L13: opt-in gate for GET /manifest.json — a no-op passthrough unless
      # `manifest_auth:` was given to `use AshRemote.Server.Router, ...`.
      # `{module, plug_opts}` runs `module.call(conn, module.init(plug_opts))`;
      # a bare module runs with `init([])`. A plug that halts the conn stops
      # the manifest from being served, same as any other Plug pipeline.
      # Branched at THIS macro's own compile time (manifest_auth_module is a
      # plain Elixir value here, not runtime-quoted state) so the generated
      # module gets exactly one clause, not a runtime module-attribute check.
      unquote(
        if manifest_auth_module do
          quote do
            defp ash_remote_run_manifest_auth(conn) do
              unquote(manifest_auth_module).call(
                conn,
                unquote(manifest_auth_module).init(unquote(Macro.escape(manifest_auth_opts)))
              )
            end
          end
        else
          quote do
            defp ash_remote_run_manifest_auth(conn), do: conn
          end
        end
      )
    end
  end
end
