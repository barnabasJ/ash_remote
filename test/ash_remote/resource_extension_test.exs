defmodule AshRemote.ResourceExtensionTest do
  use ExUnit.Case, async: true

  alias AshRemote.Resource.Info

  test "remote? detects the extension" do
    assert Info.remote?(AshRemote.Ext.Todo)
    refute Info.remote?(AshRemote.Backend.Todo)
  end

  test "Info reads the remote block" do
    assert Info.remote_source!(AshRemote.Ext.Todo) == "AshRemote.Backend.Todo"
    assert Info.remote_action_map!(AshRemote.Ext.Todo) == [read: :read]
    assert {:ok, "1.0.0"} = Info.remote_schema_version(AshRemote.Ext.Todo)
  end

  test "the validation verifier is registered on the extension" do
    assert AshRemote.Resource.Verifiers.ValidateRemote in AshRemote.Resource.verifiers()
  end
end
