defmodule AshRemote.DecoderTest do
  @moduledoc """
  M11: `decode_records/4` must always return `{:ok, [record]}` or a typed
  `{:error, _}` — never crash on a malformed/get?-ambiguous response shape,
  and never silently accept a shape the protocol doesn't allow.
  """
  use ExUnit.Case, async: true

  alias AshRemote.Client.Todo
  alias AshRemote.Decoder

  defp plan, do: elem(Decoder.write_fields(Todo), 1)

  describe "decode_records/4 — ordinary list shapes (unchanged)" do
    test "a bare list decodes to {:ok, [records]}" do
      assert {:ok, [%Todo{}]} =
               Decoder.decode_records([%{"id" => Ash.UUID.generate()}], Todo, plan())
    end

    test "a paginated %{\"results\" => [...]} decodes to {:ok, [records]}" do
      page = %{"results" => [%{"id" => Ash.UUID.generate()}], "count" => 1, "type" => "offset"}
      assert {:ok, [%Todo{}]} = Decoder.decode_records(page, Todo, plan())
    end

    test "an empty list decodes to {:ok, []}" do
      assert {:ok, []} = Decoder.decode_records([], Todo, plan())
    end
  end

  describe "decode_records/4 — get?: true (single-target reads)" do
    test "a bare single object decodes to a one-element list" do
      # Unfixed: decode_records/3 had no clause for a bare map at all —
      # FunctionClauseError out of run_query/2, no rescue.
      assert {:ok, [%Todo{}]} =
               Decoder.decode_records(%{"id" => Ash.UUID.generate()}, Todo, plan(), get?: true)
    end

    test "an explicit null (a legitimate miss) decodes to []" do
      assert {:ok, []} = Decoder.decode_records(nil, Todo, plan(), get?: true)
    end
  end

  describe "decode_records/4 — get?: false (ordinary reads), malformed shapes" do
    test "a bare single object is a typed protocol error, not silently accepted" do
      # Guards against a blanket `decode_records(map) -> [decode(map)]` fix
      # that would silently accept a malformed bare-object list response.
      assert {:error, [%{"type" => "framework"}]} =
               Decoder.decode_records(%{"id" => Ash.UUID.generate()}, Todo, plan(), get?: false)
    end

    test "an explicit null is a typed protocol error, not []" do
      # Guards against a blanket `nil -> []` fix that would silently accept
      # null where a list is required.
      assert {:error, [%{"type" => "framework"}]} =
               Decoder.decode_records(nil, Todo, plan(), get?: false)
    end

    test "get?: false is the default when opts are omitted" do
      assert {:error, [%{"type" => "framework"}]} = Decoder.decode_records(nil, Todo, plan())
    end
  end
end
