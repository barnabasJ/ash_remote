if Code.ensure_loaded?(Phoenix.Channel) do
  defmodule AshRemote.Server.Channel do
    @moduledoc """
    The `Phoenix.Channel` that carries realtime `ash_remote` notifications. One
    topic per `{resource[, tenant]}`; join is the authorization gate.

    On join it:

      1. parses the topic (`AshRemote.Topics.parse/1`);
      2. resolves the wire source to a resource that has ≥1 publication in the
         mounted otp_app (`AshRemote.Server.publications/1`);
      3. enforces tenant discipline — a multitenant resource requires a tenant
         segment, an untenanted resource rejects one;
      4. calls the host socket's `authorize_subscription/4` (default deny).

    There is no `handle_in`/intercept: `AshRemote.Server.Notifier` broadcasts land
    on the joined topic and Phoenix fast-lanes them straight to the client as the
    `"notification"` event.
    """
    use Phoenix.Channel

    require Logger

    alias AshRemote.Topics

    @impl true
    def join("ash_remote:" <> _ = topic, params, socket) do
      with {:ok, source, tenant} <- parse_topic(topic),
           {:ok, resource} <- resolve_resource(socket, source),
           :ok <- check_tenant(resource, tenant),
           {:ok, socket} <- authorize(socket, resource, tenant, params) do
        {:ok, socket}
      else
        {:error, reason} -> {:error, %{reason: reason}}
      end
    end

    def join(_topic, _params, _socket), do: {:error, %{reason: "unknown_topic"}}

    defp parse_topic(topic) do
      case Topics.parse(topic) do
        {:ok, source, tenant} -> {:ok, source, tenant}
        :error -> {:error, "invalid_topic"}
      end
    end

    defp resolve_resource(socket, source) do
      otp_app = socket.assigns.ash_remote_otp_app

      published_resources =
        otp_app |> AshRemote.Server.publications() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      module = Module.concat([source])

      if module in published_resources do
        {:ok, module}
      else
        {:error, "unknown_resource"}
      end
    rescue
      ArgumentError -> {:error, "unknown_resource"}
    end

    defp check_tenant(resource, tenant) do
      multitenant? = not is_nil(Ash.Resource.Info.multitenancy_strategy(resource))

      cond do
        multitenant? and is_nil(tenant) -> {:error, "tenant_required"}
        not multitenant? and not is_nil(tenant) -> {:error, "tenant_not_supported"}
        true -> :ok
      end
    end

    defp authorize(socket, resource, tenant, params) do
      if dangerously_allow_all?() do
        {:ok, socket}
      else
        socket_module = socket.assigns.ash_remote_socket_module

        case socket_module.authorize_subscription(resource, tenant, params, socket) do
          :ok -> {:ok, socket}
          {:ok, socket} -> {:ok, socket}
          _ -> {:error, "unauthorized"}
        end
      end
    end

    defp dangerously_allow_all? do
      if Application.get_env(:ash_remote, :dangerously_allow_all_subscriptions, false) do
        warn_dangerous_once()
        true
      else
        false
      end
    end

    @dangerous_warned {__MODULE__, :dangerous_warned}

    defp warn_dangerous_once do
      unless :persistent_term.get(@dangerous_warned, false) do
        :persistent_term.put(@dangerous_warned, true)

        Logger.warning(
          "ash_remote: :dangerously_allow_all_subscriptions is enabled — ALL realtime " <>
            "subscriptions are allowed without authorization. Do not use this in production."
        )
      end
    end
  end
end
