defmodule AshRemote.Backend.ManifestAuthPlug do
  @moduledoc """
  L13 test fixture: a minimal auth Plug for `manifest_auth:` — requires an
  `x-manifest-key` header matching `opts[:key]`, halting with 401 otherwise.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    expected = Keyword.fetch!(opts, :key)

    case get_req_header(conn, "x-manifest-key") do
      [^expected] ->
        conn

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{"success" => false, "errors" => [%{"type" => "unauthorized"}]})
        )
        |> halt()
    end
  end
end

defmodule AshRemote.Backend.ManifestAuthRouter do
  @moduledoc "L13 test fixture: the reference backend's router, with manifest_auth: enabled."
  use AshRemote.Server.Router,
    otp_app: :ash_remote,
    manifest_auth: {AshRemote.Backend.ManifestAuthPlug, key: "s3cr3t"}
end
