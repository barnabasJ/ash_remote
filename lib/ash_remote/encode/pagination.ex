defmodule AshRemote.Encode.Pagination do
  @moduledoc "Encode limit/offset into the wire `page` params."

  @doc """
  Build a page map from a query, or `nil` when there is no real pagination.

  Ash calls the data layer's `offset/3` with `0` for ordinary reads (because the
  layer advertises `:offset`); a `0` offset with no limit is not pagination, so
  we omit it rather than forcing the backend action to support pagination.
  """
  def encode(%AshRemote.Query{limit: limit, offset: offset}) do
    map =
      %{}
      |> put("limit", limit)
      |> put_offset(offset)

    if map == %{}, do: nil, else: map
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp put_offset(map, nil), do: map
  defp put_offset(map, 0), do: map
  defp put_offset(map, offset), do: Map.put(map, "offset", offset)
end
