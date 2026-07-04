defmodule AshRemote.Backend.TestBackend do
  @moduledoc """
  Test helper: boots the reference backend HTTP server (Bandit + the ported RPC
  router) once on a fixed port, and resets ETS data on demand.
  """

  @port 4747
  @base_url "http://127.0.0.1:#{@port}"

  @doc "The base URL the reference backend listens on."
  def base_url, do: @base_url

  @doc "Start the backend server (idempotent — a second call is a no-op)."
  def start do
    install_counter!()

    case Bandit.start_link(plug: __MODULE__.CountingRouter, port: @port, startup_log: false) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:shutdown, {:failed_to_start_child, _, :eaddrinuse}}} -> {:ok, :already_listening}
      other -> other
    end
  end

  @doc "Delete all ETS-backed rows for the reference backend resources."
  def reset! do
    for resource <- Ash.Domain.Info.resources(AshRemote.Backend.Domain) do
      resource
      |> Ash.read!()
      |> Enum.each(&Ash.destroy!/1)
    end

    :ok
  end

  @counter_key :ash_remote_test_rpc_counter

  @doc "Number of /rpc/run requests the backend has served."
  def rpc_count do
    :counters.get(:persistent_term.get(@counter_key), 1)
  end

  @doc "Reset the /rpc/run request counter."
  def reset_rpc_count! do
    :counters.put(:persistent_term.get(@counter_key), 1, 0)
    :ok
  end

  defp install_counter! do
    :persistent_term.put(@counter_key, :counters.new(1, [:atomics]))
  end

  defmodule CountingRouter do
    @moduledoc false
    def init(opts), do: AshRemote.Backend.RpcRouter.init(opts)

    def call(%Plug.Conn{request_path: "/rpc/run"} = conn, opts) do
      counter = :persistent_term.get(:ash_remote_test_rpc_counter)
      :counters.add(counter, 1, 1)
      conn |> put_actor() |> AshRemote.Backend.RpcRouter.call(opts)
    end

    def call(conn, opts), do: conn |> put_actor() |> AshRemote.Backend.RpcRouter.call(opts)

    # Stand-in for a host auth plug (e.g. ash_authentication): turn a forwarded
    # header — an explicit test header OR a Bearer token — into an actor via
    # Ash.PlugHelpers, which AshRemote.Server.Router reads.
    defp put_actor(conn) do
      case actor_id(conn) do
        nil -> conn
        actor_id -> Ash.PlugHelpers.set_actor(conn, %{id: actor_id})
      end
    end

    defp actor_id(conn) do
      case Plug.Conn.get_req_header(conn, "x-test-actor-id") do
        [actor_id | _] -> actor_id
        [] -> bearer_token(conn)
      end
    end

    defp bearer_token(conn) do
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> token
        _ -> nil
      end
    end
  end
end
