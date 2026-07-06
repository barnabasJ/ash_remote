defmodule AshRemote.Test.MultiDatalayer.SpyOrchestrator do
  @moduledoc """
  Stands in for a non-ProvenCoverage strategy (e.g. LocalOutbox): a genuinely
  distinct orchestrator module whose inbound reactions are observable. It proves
  the `AshRemote.MultiDatalayer.*` utilities dispatch per the resource's own
  configured orchestrator (resolved via
  `AshMultiDatalayer.DataLayer.Info.orchestrator/1`) rather than hard-coding
  ProvenCoverage.

  The structural callbacks borrow ProvenCoverage's behaviour so the resource is
  a fully-working multi-datalayer resource; only the two inbound reactions are
  overridden to report to a watching test process.
  """
  @behaviour AshMultiDatalayer.Orchestrator

  alias AshMultiDatalayer.Orchestrator.ProvenCoverage

  @probe_key {__MODULE__, :probe}

  @doc "Register `pid` to receive `{:external_change | :external_gap, ...}` reports."
  def watch(pid \\ self()), do: :persistent_term.put(@probe_key, pid)

  @impl true
  defdelegate read(query, resource), to: ProvenCoverage
  @impl true
  defdelegate create(resource, changeset), to: ProvenCoverage
  @impl true
  defdelegate update(resource, changeset), to: ProvenCoverage
  @impl true
  defdelegate upsert(resource, changeset, keys, identity), to: ProvenCoverage
  @impl true
  defdelegate destroy(resource, changeset), to: ProvenCoverage
  @impl true
  defdelegate authority(resource), to: ProvenCoverage
  @impl true
  defdelegate transaction_layer(resource), to: ProvenCoverage
  @impl true
  defdelegate can?(resource, feature), to: ProvenCoverage

  @impl true
  def handle_external_change(resource, notification) do
    report({:external_change, resource, notification.data})
    :ok
  end

  @impl true
  def handle_external_gap(resource, tenant) do
    report({:external_gap, resource, tenant})
    :ok
  end

  defp report(msg) do
    case :persistent_term.get(@probe_key, nil) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end
end
