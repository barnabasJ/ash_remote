defmodule AshRemote.ServerChannelTest do
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest

  @endpoint AshRemote.Backend.Endpoint

  setup do
    {:ok, socket} = connect(AshRemote.Backend.RemoteSocket, %{})
    %{socket: socket}
  end

  describe "join authorization" do
    test "allows a published resource when the host authorizes", %{socket: socket} do
      assert {:ok, _reply, _joined} =
               subscribe_and_join(socket, "ash_remote:AshRemote.Backend.Todo", %{})
    end

    test "denies when the host's authorize_subscription/4 returns non-ok", %{socket: socket} do
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "ash_remote:AshRemote.Backend.Todo", %{"deny" => true})
    end

    test "rejects a resource that has no publications", %{socket: socket} do
      assert {:error, %{reason: "unknown_resource"}} =
               subscribe_and_join(socket, "ash_remote:Nope.NotAResource", %{})
    end
  end

  describe "tenant discipline" do
    test "an untenanted resource rejects a tenant segment", %{socket: socket} do
      assert {:error, %{reason: "tenant_not_supported"}} =
               subscribe_and_join(socket, "ash_remote:AshRemote.Backend.Todo:org_1", %{})
    end
  end

  describe "default authorization" do
    test "the socket macro defaults to deny" do
      assert AshRemote.Backend.DefaultDenySocket.authorize_subscription(
               AshRemote.Backend.Todo,
               nil,
               %{},
               %{}
             ) == :error
    end
  end
end
