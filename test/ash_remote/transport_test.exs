defmodule AshRemote.TransportTest do
  @moduledoc "M1 integration: protocol + Req transport against the live backend."
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.{Protocol, Transport}
  alias AshRemote.Transport.Config
  alias AshRemote.Backend.TestBackend

  setup do
    TestBackend.reset!()
    {:ok, config: Config.new(base_url: TestBackend.base_url())}
  end

  test "run: create then read via protocol + transport", %{config: config} do
    create =
      Protocol.build_run(%{
        resource: "AshRemote.Backend.User",
        action: "create",
        input: %{"name" => "Ada", "email" => "ada@example.com"},
        fields: ["id", "name"]
      })

    assert {:ok, resp} = Transport.Req.request(config, :run, create)
    assert {:ok, %{"id" => id, "name" => "Ada"}} = Protocol.parse_run(resp)
    assert is_binary(id)
  end

  test "validate: invalid input yields typed errors", %{config: config} do
    body = Protocol.build_validate(%{resource: "AshRemote.Backend.Todo", action: "create", input: %{}})

    assert {:ok, resp} = Transport.Req.request(config, :validate, body)
    assert {:error, errors} = Protocol.parse_validate(resp)
    assert %Ash.Error.Invalid{} = AshRemote.Error.to_ash_error(errors)
  end

  test "transport error on unreachable host" do
    config = Config.new(base_url: "http://127.0.0.1:1", receive_timeout: 200)
    body = Protocol.build_run(%{resource: "R", action: "read"})
    assert {:error, {:transport_error, _}} = Transport.Req.request(config, :run, body)
  end

  describe "debug_requests" do
    import ExUnit.CaptureLog

    setup do
      on_exit(fn -> Application.delete_env(:ash_remote, :debug_requests) end)
    end

    test "logs every request with outcome and bodies when enabled", %{config: config} do
      Application.put_env(:ash_remote, :debug_requests, true)

      body =
        Protocol.build_run(%{
          resource: "AshRemote.Backend.User",
          action: "create",
          input: %{"name" => "Ada", "email" => "ada@example.com"},
          fields: ["id", "name"]
        })

      log = capture_log(fn -> Transport.Req.request(config, :run, body) end)

      assert log =~ "ash_remote: POST"
      assert log =~ "/rpc/run AshRemote.Backend.User.create → ok"
      assert log =~ "request:  %{"
      assert log =~ ~s("action" => "create")
      assert log =~ "response: %{"
      assert log =~ ~s("success" => true)
    end

    test "logs transport errors when enabled" do
      Application.put_env(:ash_remote, :debug_requests, true)
      config = Config.new(base_url: "http://127.0.0.1:1", receive_timeout: 200)
      body = Protocol.build_run(%{resource: "R", action: "read"})

      log = capture_log(fn -> Transport.Req.request(config, :run, body) end)

      assert log =~ "R.read → transport error:"
    end

    test "is silent by default", %{config: config} do
      body = Protocol.build_run(%{resource: "AshRemote.Backend.User", action: "read"})

      log = capture_log(fn -> Transport.Req.request(config, :run, body) end)

      refute log =~ "ash_remote: POST"
    end
  end
end
