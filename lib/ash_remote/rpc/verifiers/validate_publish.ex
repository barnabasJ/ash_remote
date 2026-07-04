defmodule AshRemote.Rpc.Verifiers.ValidatePublish do
  @moduledoc """
  Compile-time checks for the `rpc` block's realtime surface:

    * every `publish`/`no_publish` entry must name a real action on its resource;
    * when a `pub_sub` is configured (realtime is intended) but a resource with
      publications does not attach `AshRemote.Server.Notifier`, warn — that
      resource's mutations will never be broadcast.
  """
  use Spark.Dsl.Verifier

  alias AshRemote.Rpc.Info

  @notifier AshRemote.Server.Notifier

  @impl true
  def verify(dsl) do
    module = Spark.Dsl.Verifier.get_persisted(dsl, :module)
    pub_sub = Info.pub_sub(dsl)

    Enum.reduce_while(Info.rpc(dsl), :ok, fn entry, :ok ->
      case verify_entry(entry, module, pub_sub) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp verify_entry(entry, module, pub_sub) do
    with :ok <- verify_actions_exist(entry, module) do
      maybe_warn_missing_notifier(entry, pub_sub)
      :ok
    end
  end

  defp verify_actions_exist(entry, module) do
    action_names = entry.resource |> Ash.Resource.Info.actions() |> MapSet.new(& &1.name)

    (entry.publish ++ entry.no_publish)
    |> Enum.find_value(:ok, fn %{action: action} = kind ->
      if MapSet.member?(action_names, action) do
        false
      else
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:rpc, :resource, dsl_key(kind), action],
           message:
             "#{dsl_key(kind)} references unknown action #{inspect(action)} on " <>
               "#{inspect(entry.resource)}"
         )}
      end
    end)
  end

  defp dsl_key(%AshRemote.Rpc.Publish{}), do: :publish
  defp dsl_key(%AshRemote.Rpc.NoPublish{}), do: :no_publish

  defp maybe_warn_missing_notifier(_entry, nil), do: :ok

  defp maybe_warn_missing_notifier(entry, _pub_sub) do
    exposed = Enum.map(entry.expose, & &1.action)
    published = Enum.map(entry.publish, & &1.action)
    opted_out = Enum.map(entry.no_publish, & &1.action)
    publications = ((exposed ++ published) |> Enum.uniq()) -- opted_out

    if publications != [] and @notifier not in Ash.Resource.Info.notifiers(entry.resource) do
      IO.warn(
        "#{inspect(entry.resource)} has realtime publications but does not attach " <>
          "#{inspect(@notifier)}; its mutations will not be broadcast. Add " <>
          "`notifiers: [#{inspect(@notifier)}]` to the resource.",
        []
      )
    end

    :ok
  end
end
