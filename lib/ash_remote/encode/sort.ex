defmodule AshRemote.Encode.Sort do
  @moduledoc """
  Encode an Ash sort (list of `{field, direction}`) into the `sort_input` string
  the backend parses with `Ash.Query.sort_input/2`.

  Modifiers: `-` desc, `++` asc-nils-first, `--` desc-nils-last, none = asc.
  """

  @doc "Encode a sort list into a comma-joined string, or `nil` when empty."
  def encode(nil), do: nil
  def encode([]), do: nil

  def encode(sort) when is_list(sort) do
    Enum.map_join(sort, ",", &encode_one/1)
  end

  defp encode_one({field, direction}), do: "#{prefix(direction)}#{field_name(field)}"
  defp encode_one(field) when is_atom(field), do: to_string(field)

  defp prefix(:asc), do: ""
  defp prefix(:asc_nils_last), do: ""
  defp prefix(:desc), do: "-"
  defp prefix(:desc_nils_first), do: "-"
  defp prefix(:asc_nils_first), do: "++"
  defp prefix(:desc_nils_last), do: "--"

  defp field_name(%{name: name}), do: name
  defp field_name(field) when is_atom(field), do: field
end
