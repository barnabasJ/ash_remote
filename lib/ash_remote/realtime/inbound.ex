defmodule AshRemote.Realtime.Inbound do
  @moduledoc """
  Turns a decoded broadcast payload into a local `%Ash.Notifier.Notification{}`
  and fires the client resource's notifiers via `Ash.Notifier.notify/1` — so a
  server-side mutation surfaces on the client exactly as if it had happened
  locally.

  The reconstructed notification carries a **synthetic changeset** (a plain
  struct, never built with `Ash.Changeset.for_*`). This is required:
  `Ash.Notifier.PubSub` dereferences `notification.changeset.resource` for
  `:_pkey` topics and `notification.changeset.to_tenant` for `:_tenant` topics,
  so a `nil` changeset crashes it.
  """

  require Logger

  alias AshRemote.Decoder

  @doc """
  Replicate one broadcast `payload` under a connection `config`:

    * `config.sources` — `%{source_string => %{resource:, action_invert:}}`
    * `config.client_id` — this connection's correlation id (for echo suppression)
    * `config.echo` — `:suppress` (default) drops the client's own writes,
      `:deliver` delivers them (marked `origin: :remote`).

  Returns `:ok` (skips silently on unmappable payloads, logging at debug level).
  """
  def replicate(%{"resource" => source} = payload, config) do
    with {:ok, %{resource: resource, action_invert: invert}} <- fetch_source(config, source),
         :ok <- check_echo(payload, config),
         {:ok, action} <- resolve_action(resource, payload["action"], invert) do
      notify(resource, action, payload)
    else
      {:skip, reason} ->
        Logger.debug(fn ->
          "ash_remote: skipped replication (#{reason}) for #{inspect(source)}"
        end)

        :ok
    end
  end

  def replicate(_payload, _config), do: :ok

  defp fetch_source(config, source) do
    case Map.get(config.sources, source) do
      nil -> {:skip, "no client resource for source"}
      entry -> {:ok, entry}
    end
  end

  # Drop the broadcast copy of the client's own write unless echo: :deliver.
  defp check_echo(payload, config) do
    origin = get_in(payload, ["origin", "client_id"])

    if config.echo == :suppress and not is_nil(config.client_id) and origin == config.client_id do
      {:skip, "echo of own write"}
    else
      :ok
    end
  end

  # Map the wire (backend) action to a local action: inverted action_map, else
  # same name, else the resource's primary action of the same type, else skip.
  # Never creates atoms (String.to_existing_atom, rescued).
  defp resolve_action(resource, %{"name" => name, "type" => type}, invert) do
    local_name = Map.get(invert, name) || existing_atom(name)

    action =
      with %{} = action <- local_name && Ash.Resource.Info.action(resource, local_name),
           true <- to_string(action.type) == type do
        action
      else
        _ -> primary_action(resource, type)
      end

    if action, do: {:ok, action}, else: {:skip, "no local action for #{inspect(name)}/#{type}"}
  end

  defp resolve_action(_resource, _action, _invert), do: {:skip, "malformed action"}

  defp primary_action(resource, type) do
    case existing_atom(type) do
      nil -> nil
      type_atom -> Ash.Resource.Info.primary_action(resource, type_atom)
    end
  end

  defp notify(resource, action, payload) do
    domain = Ash.Resource.Info.domain(resource)
    record = decode(resource, payload["data"])
    tenant = payload["tenant"]

    changeset = %Ash.Changeset{
      resource: resource,
      domain: domain,
      action: action,
      action_type: action.type,
      data: record,
      attributes: cast_changed(resource, payload["changed"]),
      tenant: tenant,
      to_tenant: tenant,
      context: %{ash_remote: %{origin: :remote}},
      valid?: true
    }

    notification = %Ash.Notifier.Notification{
      resource: resource,
      domain: domain,
      action: action,
      data: record,
      changeset: changeset,
      actor: nil,
      metadata: metadata(payload)
    }

    Ash.Notifier.notify(notification)
    :ok
  end

  defp decode(resource, data) do
    {_fields, plan} = Decoder.write_fields(resource)
    Decoder.decode_record(data, resource, plan)
  end

  defp cast_changed(resource, changed) when is_map(changed) do
    Map.new(changed, fn {name, value} ->
      atom = existing_atom(name) || name
      {atom, Decoder.cast_attribute(resource, atom, value)}
    end)
  end

  defp cast_changed(_resource, _changed), do: %{}

  defp metadata(payload) do
    user_meta = payload["metadata"] || %{}

    Map.put(user_meta, "ash_remote", %{
      origin: :remote,
      id: payload["id"],
      occurred_at: payload["occurred_at"]
    })
  end

  defp existing_atom(nil), do: nil

  defp existing_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end
end
