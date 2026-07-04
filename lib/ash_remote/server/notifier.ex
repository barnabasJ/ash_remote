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
  """
  use Ash.Notifier

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
    tenant = notification.changeset && notification.changeset.to_tenant
    source = inspect(resource)
    topic = Topics.topic(source, tenant)
    pub_sub.broadcast(topic, "notification", payload(notification, resource, source, tenant))
    :ok
  end

  @doc false
  def payload(notification, resource, source, tenant) do
    action = notification.action
    {fields, _plan} = Decoder.write_fields(resource)

    %{
      "v" => @wire_version,
      "id" => Ash.UUID.generate(),
      "resource" => source,
      "action" => %{"name" => to_string(action.name), "type" => to_string(action.type)},
      "tenant" => tenant && to_string(tenant),
      "data" => Fields.serialize(notification.data, resource, fields),
      "changed" => changed(notification, resource),
      "origin" => %{"client_id" => client_id(notification)},
      "metadata" => sanitize(notification.metadata),
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  # New values of the changeset's public attributes — populates the client's
  # synthetic changeset `attributes`.
  defp changed(%{changeset: %{attributes: attributes}}, resource) when is_map(attributes) do
    public = resource |> Ash.Resource.Info.public_attributes() |> MapSet.new(& &1.name)

    attributes
    |> Enum.filter(fn {name, _value} -> MapSet.member?(public, name) end)
    |> Map.new(fn {name, value} -> {to_string(name), value} end)
  end

  defp changed(_notification, _resource), do: %{}

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
