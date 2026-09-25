defmodule AshCloner.Namespace do
  @moduledoc """
  Re-namespacing of cloned module names: strip the source library's common
  prefix and graft the rest onto the target namespace.
  """

  @doc """
  The longest common leading segments of the given module name strings —
  never consuming the final segment of the shortest module (a leaf always
  survives the strip).
  """
  @spec common_prefix([String.t()]) :: [String.t()]
  def common_prefix([]), do: []

  def common_prefix(modules) do
    segments = Enum.map(modules, &String.split(&1, "."))

    segments
    |> Enum.reduce(&common_leading/2)
    |> then(fn common ->
      min_len = segments |> Enum.map(&length/1) |> Enum.min()
      Enum.take(common, min(length(common), min_len - 1))
    end)
  end

  @doc """
  Swap a module name's prefix for the target namespace.

      iex> AshCloner.Namespace.reprefix("MyLib.Accounts.User", ["MyLib"], "UserApp")
      "UserApp.Accounts.User"

  The prefix is given as segments (the shape `common_prefix/1` returns) and
  is dropped by length — callers are responsible for only passing modules
  the prefix was computed from.
  """
  @spec reprefix(String.t(), [String.t()], String.t()) :: String.t()
  def reprefix(module, prefix, namespace)
      when is_binary(module) and is_list(prefix) and is_binary(namespace) do
    rest =
      module
      |> String.split(".")
      |> Enum.drop(length(prefix))

    Enum.join([namespace | rest], ".")
  end

  defp common_leading(a, b) do
    a
    |> Enum.zip(b)
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> Enum.map(&elem(&1, 0))
  end
end
