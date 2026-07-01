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
end
