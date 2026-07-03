defmodule AshRemote.PrefetchCalculations do
  @moduledoc """
  Read preparation (added to generated read actions) that records which
  `AshRemote.RemoteCalculation`-backed calculations the query loads.

  The list rides the query context into `AshRemote.DataLayer`, which folds
  those calculations into the same `/rpc/run` and stashes the decoded values
  in record metadata — so when the data layer serves the read, every
  remote calculation finds its value prefetched and makes no extra request.
  When the rows come from somewhere else (a cache layer, `Ash.load/2` on
  existing records), the same list lets the first calculation fetch the
  whole bundle in one request (see `AshRemote.RemoteCalculation`).
  """
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    specs =
      query.calculations
      |> Map.values()
      |> Enum.filter(&remote_calculation?/1)
      |> Enum.map(fn calculation ->
        %{
          name: calculation_name(calculation),
          args: Map.new(calculation.context.arguments || %{})
        }
      end)
      |> Enum.uniq_by(& &1.name)

    if specs == [] do
      query
    else
      Ash.Query.set_context(query, %{ash_remote: %{prefetch_calcs: specs}})
    end
  end

  defp remote_calculation?(%{module: AshRemote.RemoteCalculation}), do: true
  defp remote_calculation?(_), do: false

  defp calculation_name(calculation) do
    Keyword.get(calculation.opts || [], :calc) || calculation.calc_name || calculation.name
  end
end
