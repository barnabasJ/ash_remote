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
    the subscriber's actor may read the specific record before pushing the
    `"notification"` event — so a subscription never reveals a row the actor
    could not have read. The actor is read from `socket.assigns[:ash_remote_actor]`
    (set by the host socket's `connect/3` or `authorize_subscription/4`).

    Following `ash_graphql`'s subscription resolver, the actor's read-policy
    **filter is computed once at join** (`Ash.can(query, actor, run_queries?:
    false, alter_source?: true)`) and each notification's record is matched
    against it **in-memory** (`Ash.Expr.eval/2`) — never a data-layer query per
    notification per client. Only a record whose filter can't be resolved from
    the wire attributes falls back to a single authorized re-read by primary key
    (skipped for destroys, whose row is gone). Resources with no authorizers skip
    the check entirely.
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
        socket =
          socket
          |> assign(:ash_remote_resource, resource)
          |> assign(:ash_remote_tenant, tenant)
          |> assign(
            :ash_remote_read_scope,
            read_scope(resource, socket.assigns[:ash_remote_actor], tenant)
          )

        {:ok, socket}
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

    # `read_scope` was computed once at join from the actor's read policy.
    defp visible?(_payload, %{assigns: %{ash_remote_read_scope: :all}}), do: true
    defp visible?(_payload, %{assigns: %{ash_remote_read_scope: :none}}), do: false

    defp visible?(payload, %{assigns: %{ash_remote_read_scope: {:filter, filter}}} = socket) do
      resource = socket.assigns.ash_remote_resource
      record = reconstruct(resource, payload)

      case eval_filter(filter, record, resource) do
        true -> true
        false -> false
        # The filter references data the wire record doesn't carry — resolve it
        # with a single authorized re-read (skipped for destroys: the row is gone).
        :unknown -> refetch_visible?(resource, record, socket, payload)
      end
    rescue
      error ->
        Logger.warning("ash_remote: subscription authorization check failed: #{inspect(error)}")
        false
    end

    defp reconstruct(resource, payload) do
      {_fields, plan} = Decoder.write_fields(resource)
      Decoder.decode_record(payload["data"], resource, plan)
    end

    # The actor's read filter, computed ONCE per subscription. `alter_source?`
    # returns the query with the read policies applied (the actor is already
    # substituted into the filter); `run_queries?: false` means no data layer is
    # touched here.
    defp read_scope(resource, actor, tenant) do
      if Ash.Resource.Info.authorizers(resource) == [] do
        :all
      else
        query =
          resource
          |> Ash.Query.set_tenant(tenant)
          |> Ash.Query.for_read(read_action(resource))

        case Ash.can(query, actor, tenant: tenant, run_queries?: false, alter_source?: true) do
          {:ok, true, %{filter: nil}} -> :all
          {:ok, true, %{filter: %Ash.Filter{expression: nil}}} -> :all
          {:ok, true, %{filter: filter}} -> {:filter, filter}
          {:ok, true} -> :all
          _ -> :none
        end
      end
    rescue
      error ->
        Logger.warning("ash_remote: could not compute subscription read scope: #{inspect(error)}")
        :none
    end

    # Evaluate the (actor-substituted) filter against the in-memory record.
    defp eval_filter(filter, record, resource) do
      case Ash.Expr.eval(filter,
             record: record,
             resource: resource,
             unknown_on_unknown_refs?: true
           ) do
        {:ok, true} -> true
        {:ok, false} -> false
        _ -> :unknown
      end
    end

    defp refetch_visible?(_resource, _record, _socket, %{"action" => %{"type" => "destroy"}}),
      do: false

    defp refetch_visible?(resource, record, socket, _payload) do
      pkey = Map.take(record, Ash.Resource.Info.primary_key(resource))

      case Ash.get(resource, pkey,
             actor: socket.assigns[:ash_remote_actor],
             tenant: socket.assigns[:ash_remote_tenant],
             authorize?: true,
             not_found_error?: false
           ) do
        {:ok, nil} -> false
        {:ok, _record} -> true
        _ -> false
      end
    rescue
      _ -> false
    end

    defp read_action(resource) do
      Ash.Resource.Info.primary_action!(resource, :read).name
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

      case AshRemote.Server.ResourceResolver.resolve(otp_app, :channel, published_resources, source) do
        {:ok, module} -> {:ok, module}
        :error -> {:error, "unknown_resource"}
      end
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
