defmodule AshRemote.Error do
  @moduledoc """
  Maps wire error payloads (`%{"type","message","path"}`) back to `Ash.Error`
  structs, preserving messages and field paths so validation errors round-trip
  usefully to the caller.
  """

  @doc """
  Convert a wire error list into an aggregated `Ash.Error` class struct suitable
  for returning from a data-layer callback as `{:error, error}`.
  """
  @spec to_ash_error([map()]) :: Ash.Error.class()
  def to_ash_error(errors) when is_list(errors) do
    errors
    |> Enum.map(&to_exception/1)
    |> Ash.Error.to_error_class()
  end

  @doc "Convert a single wire error map into an `Ash.Error` struct."
  def to_exception(%{"type" => type} = error) do
    message = error["message"] || "remote error"
    path = Enum.map(error["path"] || [], &to_atom/1)
    field = List.last(path)

    case type do
      "forbidden" ->
        Ash.Error.Forbidden.Policy.exception(custom_message: message)

      "not_found" ->
        Ash.Error.Query.NotFound.exception([])

      "required" ->
        Ash.Error.Changes.Required.exception(
          field: field || :unknown,
          type: :attribute
        )

      t when t in ["invalid", "invalid_attribute", "invalid_argument"] ->
        Ash.Error.Changes.InvalidAttribute.exception(field: field || :base, message: message)

      _ ->
        Ash.Error.Unknown.UnknownError.exception(error: message, field: field)
    end
  end

  def to_exception(other) do
    Ash.Error.Unknown.UnknownError.exception(error: inspect(other))
  end

  defp to_atom(a) when is_atom(a), do: a

  defp to_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> String.to_atom(s)
  end
end
