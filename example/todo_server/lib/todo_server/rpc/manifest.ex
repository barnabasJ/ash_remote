defmodule TodoServer.Rpc.Manifest do
  @moduledoc "Publishes the RPC-exposed surface as a JSON `Ash.Info.Manifest`."

  @entrypoints [
    {TodoServer.Todo, :read},
    {TodoServer.Todo, :create},
    {TodoServer.Todo, :update},
    {TodoServer.Todo, :complete},
    {TodoServer.Todo, :reopen},
    {TodoServer.Todo, :destroy},
    {TodoServer.User, :read},
    {TodoServer.User, :create}
  ]

  @doc "The exposed `{resource, action}` entrypoints."
  def entrypoints, do: @entrypoints

  @doc "Generate the manifest as a pretty JSON string."
  def to_json do
    {:ok, spec} =
      Ash.Info.Manifest.generate(otp_app: :todo_server, action_entrypoints: @entrypoints)

    {:ok, json} = Ash.Info.Manifest.JsonSerializer.to_json(spec, pretty: true)
    json
  end
end
