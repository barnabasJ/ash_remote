defmodule AshRemote.Formatter do
  @moduledoc """
  Field-name formatting between the client (snake_case Ash attribute names) and
  the wire.

  `ash_typescript` camelCases field names on the wire by default. `ash_remote`
  makes this pluggable; the default strategy is `:none` (snake_case on the wire),
  which keeps a decoupled `ash_remote`↔reference-backend pair simple. Set the
  strategy to `:camel` to interoperate with a camelCasing backend.
  """

  @type strategy :: :none | :camel

  @doc "Format a client field name for the wire."
  @spec format_key(atom() | String.t(), strategy()) :: String.t()
  def format_key(name, :none), do: to_string(name)
  def format_key(name, :camel), do: camelize(to_string(name))

  @doc "Parse a wire field name back to the client's snake_case name."
  @spec parse_key(String.t(), strategy()) :: String.t()
  def parse_key(name, :none), do: name
  def parse_key(name, :camel), do: Macro.underscore(name)

  @doc "Deep-format all keys of a JSON-shaped value for the wire."
  def format_keys(value, :none), do: value
  def format_keys(value, strategy), do: deep(value, &format_key(&1, strategy))

  @doc "Deep-parse all keys of a JSON-shaped value from the wire."
  def parse_keys(value, :none), do: value
  def parse_keys(value, strategy), do: deep(value, &parse_key(&1, strategy))

  defp deep(map, keyfun) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {keyfun.(to_string(k)), deep(v, keyfun)} end)
  end

  defp deep(list, keyfun) when is_list(list), do: Enum.map(list, &deep(&1, keyfun))
  defp deep(other, _keyfun), do: other

  # "foo_bar" -> "fooBar"; leaves already-camel strings alone.
  defp camelize(string) do
    case String.split(string, "_") do
      [head | rest] -> head <> Enum.map_join(rest, &String.capitalize/1)
      [] -> string
    end
  end
end
