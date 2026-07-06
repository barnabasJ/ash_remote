defmodule AshRemote.TenantWireTest do
  @moduledoc """
  R-1 (fix-plan Phase B0-1 / B1-1): tenant must cross the RPC wire on both
  `/rpc/run` and `/rpc/validate`. Pre-fix, `AshRemote.DataLayer.set_tenant/3`
  only stashes the tenant on the local query/changeset struct — it never
  reaches `AshRemote.Protocol.build_run/1`'s body, and the server resolves
  tenant only from the conn (which this test harness never sets), so a
  multitenant read/write runs untenanted: cross-tenant data leaks.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Backend.TestBackend
  alias AshRemote.Client.Note

  setup do
    TestBackend.reset!()

    Application.put_env(:ash_remote, :remote_config, %{
      Note => %{base_url: TestBackend.base_url(), source: "AshRemote.Backend.Note"}
    })

    on_exit(fn -> Application.delete_env(:ash_remote, :remote_config) end)
    :ok
  end

  test "a read under one tenant never sees another tenant's rows (/rpc/run)" do
    tenant_a = "org_a_#{System.unique_integer([:positive])}"
    tenant_b = "org_b_#{System.unique_integer([:positive])}"

    %{id: id_a} = Ash.create!(Note, %{text: "a's secret"}, tenant: tenant_a)
    %{id: _id_b} = Ash.create!(Note, %{text: "b's secret"}, tenant: tenant_b)

    # Reading as tenant A must see ONLY tenant A's row — not tenant B's, and
    # not both (which is what "tenant silently dropped" looks like).
    assert [%Note{id: ^id_a, text: "a's secret"}] = Ash.read!(Note, tenant: tenant_a)
    assert [%Note{text: "b's secret"}] = Ash.read!(Note, tenant: tenant_b)
  end

  test "the wire tenant reaches Server.validate_action independently of /rpc/run (R-1 + B1-4)" do
    params = %{
      "resource" => "AshRemote.Backend.Note",
      "action" => "create",
      "input" => %{"text" => "__echo_tenant__"}
    }

    assert %{"success" => false, "errors" => [%{"message" => message}]} =
             AshRemote.Server.validate_action(:ash_remote, params, tenant: "the-wire-tenant")

    assert message =~ ~s(tenant="the-wire-tenant")
  end
end
