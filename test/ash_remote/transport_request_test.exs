defmodule AshRemote.TransportRequestTest do
  @moduledoc """
  L7-1 (header dedupe) and L7-2 (write-retry scoping) regressions: what
  `AshRemote.DataLayer`'s private `request/5` actually hands the transport,
  observed via `AshRemote.Test.RecordingTransport` rather than by reaching
  into the private function directly.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Backend.TestBackend
  alias AshRemote.Client.Todo
  alias AshRemote.Test.RecordingTransport
  alias AshRemote.Transport.Config

  setup do
    RecordingTransport.ensure_table!()
    RecordingTransport.reset!()
    TestBackend.reset!()
    :ok
  end

  describe "L7-1: static transport-config headers vs. per-request headers" do
    setup do
      Application.put_env(:ash_remote, :remote_config, %{
        Todo => %{
          source: "AshRemote.Backend.Todo",
          transport:
            Config.new(
              base_url: TestBackend.base_url(),
              module: RecordingTransport,
              headers: [{"authorization", "Bearer static-config-token"}, {"x-static", "1"}]
            )
        }
      })

      on_exit(fn -> Application.delete_env(:ash_remote, :remote_config) end)
      :ok
    end

    test "an actor-derived token wins over the static config header, and never duplicates it" do
      actor =
        AshRemote.Backend.User
        |> struct(id: Ash.UUID.generate())
        |> Ash.Resource.put_metadata(:token, "actor-token-value")

      Ash.create!(Todo, %{title: "hello"}, actor: actor)

      [%{headers: headers}] = RecordingTransport.calls()

      auth_headers =
        Enum.filter(headers, fn {name, _value} -> String.downcase(name) == "authorization" end)

      # Unfixed: `transport.headers ++ extra_headers` hands the backend BOTH
      # the static config token and the actor token as two separate
      # `authorization` headers.
      assert [{_name, value}] = auth_headers
      # Precedence: the per-request (actor-derived) header wins.
      assert value == "Bearer actor-token-value"
      # A differently-named static header is untouched by the dedupe.
      assert {"x-static", "1"} in headers
    end

    test "with no per-request header at all, the static transport-config header survives untouched" do
      Ash.create!(Todo, %{title: "hello"})

      [%{headers: headers}] = RecordingTransport.calls()
      assert {"authorization", "Bearer static-config-token"} in headers
    end
  end

  describe "L7-2: retry is scoped to idempotent reads, never write POSTs" do
    setup do
      Application.put_env(:ash_remote, :remote_config, %{
        Todo => %{
          source: "AshRemote.Backend.Todo",
          transport:
            Config.new(
              base_url: TestBackend.base_url(),
              module: RecordingTransport,
              retry: :safe_transient
            )
        }
      })

      on_exit(fn -> Application.delete_env(:ash_remote, :remote_config) end)
      :ok
    end

    test "create/update/destroy force retry: false regardless of the configured policy" do
      todo = Ash.create!(Todo, %{title: "hello"})
      updated = Ash.update!(todo, %{title: "hello v2"})
      :ok = Ash.destroy!(updated)

      writes =
        RecordingTransport.calls()
        |> Enum.filter(&(&1.action in ["create", "update", "destroy"]))

      assert length(writes) == 3

      # Unfixed: writes go out carrying whatever `retry` the transport
      # config declares — retrying a non-idempotent POST after a transient
      # failure risks double-applying it (a duplicate create, a second
      # destroy racing a fresh row at the same id, ...).
      assert Enum.all?(writes, &(&1.retry == false))
    end

    test "reads keep the transport's configured retry policy" do
      Ash.create!(Todo, %{title: "hello"})
      RecordingTransport.reset!()

      Ash.read!(Todo)

      assert [%{action: "read", retry: :safe_transient}] = RecordingTransport.calls()
    end
  end
end
