defmodule TodoClient.Remote.Transport do
  @moduledoc "Demo RPC transport that fails fast when the online page is offline."
  @behaviour AshRemote.Transport

  @impl true
  def request(config, path, body) do
    if TodoClient.Network.offline?() do
      {:error, {:transport_error, :demo_offline}}
    else
      AshRemote.Transport.Req.request(config, path, body)
    end
  end
end
