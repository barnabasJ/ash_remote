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
end
