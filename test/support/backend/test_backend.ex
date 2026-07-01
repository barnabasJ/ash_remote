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
    case Bandit.start_link(plug: AshRemote.Backend.Rpc.Router, port: @port, startup_log: false) do
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
end
