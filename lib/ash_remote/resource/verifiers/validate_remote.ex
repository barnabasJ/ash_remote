defmodule AshRemote.Resource.Verifiers.ValidateRemote do
  @moduledoc """
  Compile-time checks for remote resources: a primary key must exist (needed to
  address records for update/destroy), and mapped actions must resolve to real
  actions on the resource.
  """
  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    module = Spark.Dsl.Verifier.get_persisted(dsl, :module)

    with :ok <- verify_primary_key(dsl, module) do
      verify_action_map(dsl, module)
    end
  end

  defp verify_primary_key(dsl, module) do
    pk =
      dsl
      |> Ash.Resource.Info.attributes()
      |> Enum.filter(& &1.primary_key?)

    if pk == [] do
      {:error,
       Spark.Error.DslError.exception(
         module: module,
         path: [:remote],
         message: "a remote resource must define a primary key"
       )}
    else
      :ok
    end
  end

  defp verify_action_map(dsl, module) do
    action_map = AshRemote.Resource.Info.remote_action_map!(dsl)
    action_names = dsl |> Ash.Resource.Info.actions() |> Enum.map(& &1.name) |> MapSet.new()

    case Enum.find(action_map, fn {client, _backend} -> client not in action_names end) do
      nil ->
        :ok

      {client, _} ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:remote, :action_map],
           message: "action_map references unknown action #{inspect(client)}"
         )}
    end
  end
end
