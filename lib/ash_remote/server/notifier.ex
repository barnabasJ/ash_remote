defmodule AshRemote.Server.Notifier do
  @moduledoc """
  An `Ash.Notifier` that broadcasts wire-shaped notifications for replication to
  subscribed `ash_remote` clients.

  Attach it to a server resource:

      use Ash.Resource, notifiers: [AshRemote.Server.Notifier]

  It fires for every `:create | :update | :destroy` on the resource. Whether a
  given `{resource, action}` is actually broadcast is decided by the resource's
  domain `rpc` block: the action must be published
  (`(exposed ∪ publish) ∖ no_publish`, see `AshRemote.Rpc.Info.publications/1`)
  and the domain must declare a `pub_sub` module exporting `broadcast/3` (e.g. a
  `Phoenix.Endpoint`). Capturing at the notifier level — not at RPC dispatch —
  means server-local writes replicate too, and Ash's transaction/bulk deferral
  come for free.

  The broadcast is `pub_sub.broadcast(topic, "notification", payload)` — the same
  contract as `Ash.Notifier.PubSub`'s `module`, so no compile-time Phoenix
  dependency. Topic and payload shape live in `AshRemote.Topics` and this
  module's `payload/4`.

  **Field policies (R-3)**: an attribute a field policy applies to NEVER
  travels over realtime, in either `"data"` or `"changed"` — this notifier
  broadcasts to every topic subscriber before any single subscriber's
  policies are known, so per-subscriber field evaluation isn't cheap the way
  a normal RPC read's is. `Server.Channel` already gates whole rows per
  subscriber; field policies are strictly finer-grained than that and are
  not evaluated here. Load a field-policied attribute via an authorized RPC
  read instead.
  """
  use Ash.Notifier

  require Logger

  alias AshRemote.{Decoder, Topics}
  alias AshRemote.Rpc.Info
  alias AshRemote.Server.Fields

  @wire_version 1

  @impl true
  def notify(%Ash.Notifier.Notification{action: %{type: type}} = notification)
      when type in [:create, :update, :destroy] do
    resource = notification.resource

    with true <- is_struct(notification.data, resource),
         domain when not is_nil(domain) <- resolve_domain(notification),
         true <- Info.rpc?(domain),
         true <- Info.publication?(domain, resource, notification.action.name),
         pub_sub when not is_nil(pub_sub) <- Info.pub_sub(domain) do
      broadcast(pub_sub, notification, resource)
    else
      _ -> :ok
    end
  end

  def notify(_notification), do: :ok

  # Notifiers are resource-level but the `rpc` publication DSL is domain-level;
  # prefer the notification's domain, else the resource's declared domain.
  defp resolve_domain(%{domain: domain}) when not is_nil(domain), do: domain
  defp resolve_domain(%{resource: resource}), do: Ash.Resource.Info.domain(resource)

  defp broadcast(pub_sub, notification, resource) do
    source = inspect(resource)

    case resolve_tenant(notification, resource) do
      {:ok, tenant} ->
        publish(pub_sub, notification, resource, source, tenant)

      :unresolvable ->
        # M8: a changeset-less mutation on a context-multitenant resource
        # (the tenant lives only in changeset/context, never on the record
        # itself) has no tenant to derive — publishing to the untenanted
        # topic would be silently unjoinable (no multitenant subscriber
        # joins it). Never guess; emit a concrete, testable signal instead
        # so a supervising reconcile job can react — logged AND telemetried,
        # not a docs-only closure.
        Logger.warning(
          "ash_remote: cannot determine tenant for a changeset-less #{source} " <>
            "notification (#{notification.action.type}) — realtime delivery skipped, " <>
            "not broadcast to an unjoinable topic"
        )

        :telemetry.execute(
          [:ash_remote, :server, :notifier, :unresolvable_tenant],
          %{count: 1},
          %{resource: resource, action: notification.action.name}
        )
    end

    :ok
  end

  # A changeset carries the authoritative tenant regardless of strategy.
  defp resolve_tenant(%{changeset: changeset}, _resource) when not is_nil(changeset) do
    {:ok, changeset.to_tenant}
  end

  # Changeset-less (e.g. a manual Ash.Notifier.notify/1 call, or a bulk
  # operation that didn't attach one): for attribute-strategy multitenancy
  # the tenant lives ON the record — read it directly rather than falling
  # back to the unjoinable untenanted topic. Context-strategy has nowhere
  # to recover it from (the record carries no tenant attribute at all).
  defp resolve_tenant(notification, resource) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      nil ->
        {:ok, nil}

      :attribute ->
        {:ok, Map.get(notification.data, Ash.Resource.Info.multitenancy_attribute(resource))}

      :context ->
        :unresolvable
    end
  end

  defp publish(pub_sub, notification, resource, source, tenant) do
    topic = Topics.topic(source, tenant)

    # Notifications are best-effort hints; a transport failure must never fail
    # the originating write.
    try do
      pub_sub.broadcast(topic, "notification", payload(notification, resource, source, tenant))
    rescue
      error ->
        Logger.warning("ash_remote: realtime broadcast to #{topic} failed: #{inspect(error)}")
    end
  end

  @doc false
  def payload(notification, resource, source, tenant) do
    action = notification.action
    {fields, _plan} = Decoder.write_fields(resource)
    policied = policy_target_fields(resource)
    wire_fields = Enum.reject(fields, &MapSet.member?(policied, &1))

    %{
      "v" => @wire_version,
      "id" => Ash.UUID.generate(),
      "resource" => source,
      "action" => %{"name" => to_string(action.name), "type" => to_string(action.type)},
      "tenant" => tenant && to_string(tenant),
      "data" => Fields.serialize(notification.data, resource, wire_fields),
      "changed" => changed(notification, resource, policied),
      "origin" => %{"client_id" => client_id(notification)},
      "metadata" => sanitize(notification.metadata),
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  # R-3: attributes a field policy applies TO (not attributes merely
  # REFERENCED by a policy condition — pass-1 W4) never travel over realtime,
  # in either serialized field: a row-visible subscriber otherwise received
  # values RPC would deny them. Computed once per notification; field
  # policies are rare enough that this isn't worth caching further. Load a
  # field-policied attribute via authorized RPC instead.
  defp policy_target_fields(resource) do
    resource
    |> Ash.Resource.Info.public_attributes()
    |> Enum.filter(fn attr ->
      case Ash.Policy.Info.field_policies_for_field(resource, attr.name) do
        policies when policies in [nil, []] -> false
        _policies -> true
      end
    end)
    |> MapSet.new(&to_string(&1.name))
  end

  # The public attributes touched by this change, with their FINAL values pulled
  # from the result record (via the same serializer as `data`). We take the value
  # from `notification.data`, never from `changeset.attributes`, because an atomic
  # update stores Ash expressions there (from validations compiled to atomics),
  # which are not JSON-encodable.
  defp changed(%{changeset: changeset} = notification, resource, policied)
       when not is_nil(changeset) do
    public = resource |> Ash.Resource.Info.public_attributes() |> MapSet.new(& &1.name)

    names =
      (Map.keys(changeset.attributes || %{}) ++ Keyword.keys(changeset.atomics || []))
      |> Enum.uniq()
      |> Enum.filter(&MapSet.member?(public, &1))
      |> Enum.map(&to_string/1)
      |> Enum.reject(&MapSet.member?(policied, &1))

    Fields.serialize(notification.data, resource, names)
  end

  defp changed(_notification, _resource, _policied), do: %{}

  defp client_id(%{changeset: %{context: context}}) when is_map(context) do
    get_in(context, [:ash_remote, :client_id])
  end

  defp client_id(_notification), do: nil

  # JSON-sanitize freeform metadata: keep primitives/maps/lists, stringify atoms,
  # drop everything else (structs, pids, funs, tuples).
  defp sanitize(value) do
    cond do
      is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value) -> value
      is_atom(value) -> to_string(value)
      is_list(value) -> Enum.map(value, &sanitize/1)
      is_struct(value) -> nil
      is_map(value) -> sanitize_map(value)
      true -> nil
    end
  end

  defp sanitize_map(map) do
    map
    |> Enum.flat_map(fn {key, value} ->
      case sanitize_key(key) do
        {:ok, key} -> [{key, sanitize(value)}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp sanitize_key(key) when is_atom(key), do: {:ok, to_string(key)}
  defp sanitize_key(key) when is_binary(key), do: {:ok, key}
  defp sanitize_key(_key), do: :error
end
