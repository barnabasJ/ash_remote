defmodule AshRemote.L13ManifestAuthTest do
  @moduledoc """
  L13 item 1: GET /manifest.json is unauthenticated by default (an explicit,
  accepted decision — see Router's moduledoc), but a host app that wants it
  gated can opt in via `manifest_auth:`. Proves the opt-in hook actually
  works: a plug that halts blocks the manifest; one that passes serves it;
  /rpc/run remains unaffected either way.
  """
  use ExUnit.Case, async: true

  alias AshRemote.Backend.ManifestAuthRouter
  alias AshRemote.Backend.RpcRouter

  test "the default router (no manifest_auth) serves /manifest.json with no auth" do
    conn = Plug.Test.conn(:get, "/manifest.json")
    conn = RpcRouter.call(conn, [])

    assert conn.status == 200
    assert conn.resp_body != ""
  end

  test "manifest_auth: without the required header is denied" do
    conn = Plug.Test.conn(:get, "/manifest.json")
    conn = ManifestAuthRouter.call(conn, [])

    assert conn.status == 401
  end

  test "manifest_auth: with a wrong header value is denied" do
    conn =
      :get
      |> Plug.Test.conn("/manifest.json")
      |> Plug.Conn.put_req_header("x-manifest-key", "wrong")

    conn = ManifestAuthRouter.call(conn, [])

    assert conn.status == 401
  end

  test "manifest_auth: with the correct header serves the manifest" do
    conn =
      :get
      |> Plug.Test.conn("/manifest.json")
      |> Plug.Conn.put_req_header("x-manifest-key", "s3cr3t")

    conn = ManifestAuthRouter.call(conn, [])

    assert conn.status == 200
    assert conn.resp_body != ""
  end

  test "manifest_auth: does not affect /rpc/run" do
    conn =
      :post
      |> Plug.Test.conn("/rpc/run", Jason.encode!(%{"resource" => "nope", "action" => "read"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = ManifestAuthRouter.call(conn, [])

    # No manifest-key header at all, and no 401 — the auth hook is scoped to
    # the manifest route only, per the moduledoc's own claim.
    refute conn.status == 401
  end
end
