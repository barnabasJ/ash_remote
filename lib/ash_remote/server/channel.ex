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

    Broadcasts are **intercepted per subscriber**: `handle_out/3` re-checks that
    the subscriber's actor may read the specific record (`Ash.can?({record,
    :read}, actor)`) and only then pushes the `"notification"` event. Join
    authorizes the topic; this authorizes each record — so a broadcast never
    reveals a row the actor could not have read. The actor is read from
    `socket.assigns[:ash_remote_actor]` (set by the host socket's `connect/3` or
    `authorize_subscription/4`). Resources with no authorizers skip the check.
    """
    use Phoenix.Channel

    require Logger

    alias AshRemote.{Decoder, Topics}

    intercept(["notification"])

    @impl true
    def join("ash_remote:" <> _ = topic, params, socket) do
      with {:ok, source, tenant} <- parse_topic(topic),
           {:ok, resource} <- resolve_resource(socket, source),
           :ok <- check_tenant(resource, tenant),
           {:ok, socket} <- authorize(socket, resource, tenant, params) do
        {:ok, assign(socket, :ash_remote_resource, resource)}
      else
        {:error, reason} -> {:error, %{reason: reason}}
      end
    end

    def join(_topic, _params, _socket), do: {:error, %{reason: "unknown_topic"}}

    # Per-record authorization: only push a broadcast to this subscriber if its
    # actor may read the record. Broadcasts fan out to every topic subscriber, so
    # this is where row-level read policies are enforced.
    @impl true
    def handle_out("notification", payload, socket) do
      if visible?(payload, socket) do
        push(socket, "notification", payload)
      end

      {:noreply, socket}
    end

    defp visible?(payload, socket) do
      resource = socket.assigns.ash_remote_resource

      # No authorizers → nothing to enforce (and no `Ash.can?` overhead).
      if Ash.Resource.Info.authorizers(resource) == [] do
        true
      else
        actor = socket.assigns[:ash_remote_actor]
        record = reconstruct(resource, payload)
        authorized_to_read?(record, actor)
      end
    end

    defp reconstruct(resource, payload) do
      {_fields, plan} = Decoder.write_fields(resource)
      Decoder.decode_record(payload["data"], resource, plan)
    end

    # Deny (drop the notification) if the check errors — fail closed.
    defp authorized_to_read?(record, actor) do
      Ash.can?({record, :read}, actor)
    rescue
      error ->
        Logger.warning("ash_remote: subscription authorization check failed: #{inspect(error)}")
        false
    end

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
