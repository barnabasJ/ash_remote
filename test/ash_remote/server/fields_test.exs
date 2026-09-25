defmodule AshRemote.Server.FieldsTest do
  @moduledoc """
  Unit coverage for `AshRemote.Server.Fields` sentinel handling — retained
  regression for #27 (fixed in the uncommitted working tree before this run):
  a field-policy-denied or unselected field must serialize to a safe value,
  never reach `Jason.encode!` as an un-encodable struct. `%Ash.NotSelected{}`
  does not exist in this Ash version (only `Ash.NotLoaded`/`Ash.ForbiddenField`)
  — see the B1 task spec correction.
  """
  use ExUnit.Case, async: true

  alias AshRemote.Backend.Todo
  alias AshRemote.Server.Fields

  test "a field-policy-denied field (%Ash.ForbiddenField{}) serializes to nil, not the struct" do
    record = %Todo{id: "1", title: %Ash.ForbiddenField{field: :title, type: :attribute}}

    assert Fields.serialize(record, Todo, ["title"]) == %{"title" => nil}
  end

  test "an unselected field (%Ash.NotLoaded{type: :attribute}) serializes to nil" do
    record = %Todo{id: "1", title: %Ash.NotLoaded{type: :attribute, field: :title}}

    assert Fields.serialize(record, Todo, ["title"]) == %{"title" => nil}
  end

  describe "microsecond-precision dump regression (H-utc-precision)" do
    # A `:utc_datetime`-declared calculation's raw computed value isn't
    # guaranteed to already be a canonical instance of the type — an
    # expression-based calc backed by a raw DB fragment hands back whatever
    # the driver decoded (Postgrex always carries `{0, 6}` microsecond
    # precision on a `timestamptz`, even when every digit is zero).
    # `Ecto.Type.dump/2` for `:utc_datetime` requires literal `{0, 0}` and
    # raises `ArgumentError` otherwise — this crashed a real `/ash_remote/rpc`
    # request end to end (arcc-center's `Session.start_datetime`/
    # `end_datetime`, both `:utc_datetime`-typed `remote(...)` mirrors).
    test "a calc value with non-empty (but zero) microsecond precision serializes without crashing" do
      raw = %DateTime{
        DateTime.utc_now()
        | microsecond: {0, 6},
          year: 2024,
          month: 1,
          day: 1,
          hour: 0,
          minute: 0,
          second: 0
      }

      record = %Todo{id: "1", calculations: %{fixed_point_in_time: raw}}

      result = Fields.serialize(record, Todo, ["fixed_point_in_time"])

      assert %{"fixed_point_in_time" => %DateTime{microsecond: {0, 0}}} = result
      assert Jason.encode!(result) =~ ~s("fixed_point_in_time":"2024-01-01T00:00:00Z")
    end

    test "a calc value already at {0, 0} precision still serializes correctly" do
      raw = %DateTime{
        DateTime.utc_now()
        | microsecond: {0, 0},
          year: 2024,
          month: 1,
          day: 1,
          hour: 0,
          minute: 0,
          second: 0
      }

      record = %Todo{id: "1", calculations: %{fixed_point_in_time: raw}}

      result = Fields.serialize(record, Todo, ["fixed_point_in_time"])

      assert %{"fixed_point_in_time" => %DateTime{microsecond: {0, 0}}} = result
      assert Jason.encode!(result) =~ ~s("fixed_point_in_time":"2024-01-01T00:00:00Z")
    end
  end
end
