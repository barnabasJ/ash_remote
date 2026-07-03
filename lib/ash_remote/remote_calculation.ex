defmodule AshRemote.RemoteCalculation do
  @moduledoc """
  A calculation whose values are computed by the remote backend and proxied
  by name — used by the generator for every calculation whose expression
  cannot be mirrored as data (module calculations, unsupported expression
  shapes).

      calculate :title_with_prefix, :string,
                {AshRemote.RemoteCalculation, calc: :title_with_prefix}

  Values always come from the server, so the calculation returns identical
  results no matter which data layer served the rows (plain ash_remote, or a
  cache layer via ash_multi_datalayer). Two paths:

    * **Prefetched**: when the read went through `AshRemote.DataLayer`, the
      `AshRemote.PrefetchCalculations` preparation had the data layer fold
      every requested remote calculation into the same `/rpc/run`; the values
      sit in record metadata and are picked out here with no extra request.
    * **Bundled fetch**: when the rows came from elsewhere (a cache layer, or
      `Ash.load/2` on existing records), the FIRST remote calculation to run
      fetches the whole requested bundle — all remote calculations, all
      records — in one request (`primary_key in [...]`), memoized for the
      read so sibling calculations just pick out their column.

  No `expression/2` is defined on purpose: Ash therefore refuses filtering
  and sorting on these calculations (its native behaviour for Elixir
  calculations) — a placeholder expression evaluable anywhere would
  eventually be evaluated somewhere it is wrong.
  """
  use Ash.Resource.Calculation

  @impl true
  def calculate([], _opts, _context), do: {:ok, []}

  def calculate(records, opts, context) do
    name = Keyword.fetch!(opts, :calc)
    resource = hd(records).__struct__
    metadata_key = {:ash_remote_calc, name}
    [pk] = Ash.Resource.Info.primary_key(resource)

    missing = Enum.reject(records, &prefetched?(&1, metadata_key))

    with {:ok, fetched} <- fetched_values(missing, resource, name, context) do
      {:ok,
       Enum.map(records, fn record ->
         if prefetched?(record, metadata_key) do
           record.__metadata__[metadata_key]
         else
           Map.get(fetched, to_string(Map.get(record, pk)))
         end
       end)}
    end
  end

  defp prefetched?(record, metadata_key) do
    is_map(record.__metadata__) and Map.has_key?(record.__metadata__, metadata_key)
  end

  defp fetched_values([], _resource, _name, _context), do: {:ok, %{}}

  defp fetched_values(records, resource, name, context) do
    args = Map.new(context.arguments || %{})
    specs = bundle_specs(context, name, args)
    [pk] = Ash.Resource.Info.primary_key(resource)
    pk_values = Enum.map(records, &Map.get(&1, pk))

    memo_key = {__MODULE__, resource, :erlang.phash2({pk_values, specs})}

    case Process.get(memo_key) do
      nil ->
        with {:ok, bundle} <-
               AshRemote.DataLayer.fetch_remote_calculations(resource, pk_values, specs) do
          Process.put(memo_key, bundle)
          {:ok, Map.get(bundle, name, %{})}
        end

      bundle ->
        {:ok, Map.get(bundle, name, %{})}
    end
  end

  # All remote calculations requested by the read (recorded by the
  # PrefetchCalculations preparation), so one request serves them all; when
  # invoked outside a prepared read, fall back to just this calculation.
  defp bundle_specs(context, name, args) do
    recorded = get_in(context.source_context || %{}, [:ash_remote, :prefetch_calcs]) || []

    if Enum.any?(recorded, &(&1.name == name)) do
      recorded
    else
      [%{name: name, args: args} | recorded]
    end
  end
end
