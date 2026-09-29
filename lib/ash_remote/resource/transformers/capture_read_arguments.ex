defmodule AshRemote.Resource.Transformers.CaptureReadArguments do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  # Get-by actions gain their arguments in Ash's transformer. Run after it so
  # every parameterized read receives capture as its final preparation.
  def after?(Ash.Resource.Transformers.GetByReadActions), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl) do
    {:ok, preparation} = Ash.Resource.Builder.build_preparation(AshRemote.CaptureArguments)

    dsl =
      dsl
      |> Transformer.get_entities([:actions])
      |> Enum.filter(&(&1.type == :read and &1.arguments != []))
      |> Enum.reduce(dsl, fn action, dsl ->
        if Enum.any?(action.preparations, fn
             %Ash.Resource.Preparation{preparation: {AshRemote.CaptureArguments, _}} -> true
             _ -> false
           end) do
          dsl
        else
          action = %{action | preparations: action.preparations ++ [preparation]}

          Transformer.replace_entity(
            dsl,
            [:actions],
            action,
            &(&1.type == :read and &1.name == action.name)
          )
        end
      end)

    {:ok, dsl}
  end
end
