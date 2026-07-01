defmodule AshRemote.Encode.Pagination do
  @moduledoc "Encode limit/offset into the wire `page` params."

  @doc "Build a page map from a query, or `nil` when unpaginated."
  def encode(%AshRemote.Query{limit: nil, offset: nil}), do: nil

  def encode(%AshRemote.Query{limit: limit, offset: offset}) do
    %{}
    |> put("limit", limit)
    |> put("offset", offset)
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
