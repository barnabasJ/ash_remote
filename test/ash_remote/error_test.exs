defmodule AshRemote.ErrorTest do
  use ExUnit.Case, async: true

  alias AshRemote.Error

  test "maps required errors to Ash.Error.Changes.Required preserving field" do
    error =
      Error.to_exception(%{"type" => "required", "message" => "is required", "path" => ["title"]})

    assert %Ash.Error.Changes.Required{field: :title} = error
  end

  test "maps invalid to InvalidAttribute preserving message" do
    error = Error.to_exception(%{"type" => "invalid", "message" => "bad", "path" => ["status"]})
    assert %Ash.Error.Changes.InvalidAttribute{field: :status, message: "bad"} = error
  end

  test "maps not_found and forbidden" do
    assert %Ash.Error.Query.NotFound{} = Error.to_exception(%{"type" => "not_found"})

    assert %Ash.Error.Forbidden.Policy{} =
             Error.to_exception(%{"type" => "forbidden", "message" => "no"})
  end

  test "unknown types fall back to UnknownError with the message" do
    error = Error.to_exception(%{"type" => "weird", "message" => "boom"})
    assert %Ash.Error.Unknown.UnknownError{error: "boom"} = error
  end

  test "to_ash_error aggregates into an Ash error class" do
    class = Error.to_ash_error([%{"type" => "required", "path" => ["title"]}])
    assert Ash.Error.ash_error?(class)
    assert class.class == :invalid
  end
end
