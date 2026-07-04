defmodule AshRemote.Topics do
  @moduledoc """
  Channel topic naming for realtime replication, shared by the server notifier
  and the client subscriber. Dependency-free (no Phoenix/Slipstream) so both
  sides can compute and match topics without pulling the optional transports.

  Shape: `ash_remote:<source>[:<tenant>]` where `source` is the wire resource
  string (a manifest module string, e.g. `"TodoServer.Todo"`). Module strings
  never contain `:`, so the source is always the segment immediately after the
  prefix and the tenant is the (possibly `:`-containing) remainder.
  """

  @prefix "ash_remote"

  @doc "The topic prefix (`\"ash_remote\"`)."
  def prefix, do: @prefix

  @doc """
  Build the topic for a wire `source` and optional `tenant`.

      iex> AshRemote.Topics.topic("TodoServer.Todo")
      "ash_remote:TodoServer.Todo"
      iex> AshRemote.Topics.topic("TodoServer.Todo", "org_1")
      "ash_remote:TodoServer.Todo:org_1"
  """
  def topic(source, tenant \\ nil)
  def topic(source, nil), do: @prefix <> ":" <> to_string(source)

  def topic(source, tenant),
    do: @prefix <> ":" <> to_string(source) <> ":" <> to_string(tenant)

  @doc """
  Parse a topic back into `{:ok, source, tenant | nil}` or `:error`.

      iex> AshRemote.Topics.parse("ash_remote:TodoServer.Todo")
      {:ok, "TodoServer.Todo", nil}
      iex> AshRemote.Topics.parse("ash_remote:TodoServer.Todo:org_1")
      {:ok, "TodoServer.Todo", "org_1"}
      iex> AshRemote.Topics.parse("other:thing")
      :error
  """
  def parse(@prefix <> ":" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [source] when source != "" -> {:ok, source, nil}
      [source, tenant] when source != "" and tenant != "" -> {:ok, source, tenant}
      _ -> :error
    end
  end

  def parse(_), do: :error
end
