defmodule TodoClient.Test.CountingRouter do
  @moduledoc """
  Wraps the backend's full web router (auth + RPC), counting every
  `/rpc/run` request — the wire-level ground truth for "this read did not
  touch the server".
  """

  @counter_key :todo_client_rpc_counter

  def install_counter! do
    :persistent_term.put(@counter_key, :counters.new(1, [:atomics]))
  end

  def rpc_count do
    :counters.get(:persistent_term.get(@counter_key), 1)
  end

  def reset! do
    :counters.put(:persistent_term.get(@counter_key), 1, 0)
    :ok
  end

  def init(opts), do: TodoServer.WebRouter.init(opts)

  def call(%Plug.Conn{request_path: "/rpc/run"} = conn, opts) do
    :counters.add(:persistent_term.get(@counter_key), 1, 1)
    TodoServer.WebRouter.call(conn, opts)
  end

  def call(conn, opts), do: TodoServer.WebRouter.call(conn, opts)
end
