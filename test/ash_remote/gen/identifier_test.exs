defmodule AshRemote.Gen.IdentifierTest do
  @moduledoc """
  Unit coverage for the predicate/raising pair `AshRemote.Gen` uses to guard
  every manifest-sourced name it splices into generated source. Integration
  coverage (that `AshRemote.Gen.generate/2` actually calls these at every
  injection point) lives in `AshRemote.GenTest`'s "identifier safety (L6)"
  describe block.
  """
  use ExUnit.Case, async: true

  alias AshRemote.Gen.{Identifier, InvalidManifestError}

  describe "name?/1" do
    test "accepts ordinary snake_case identifiers" do
      assert Identifier.name?("title")
      assert Identifier.name?("comment_count")
      assert Identifier.name?("_private")
    end

    test "accepts identifiers ending in ? or !" do
      assert Identifier.name?("is_overdue?")
      assert Identifier.name?("save!")
    end

    test "accepts atoms unconditionally (already-trusted, not manifest text)" do
      assert Identifier.name?(:id)
      assert Identifier.name?(:"weird atom with spaces")
    end

    test "rejects an empty string" do
      refute Identifier.name?("")
    end

    test "rejects a name starting with a digit" do
      refute Identifier.name?("1foo")
    end

    test "rejects names containing whitespace, quotes, or newlines" do
      refute Identifier.name?("foo bar")
      refute Identifier.name?(~s|foo", evil: 1|)
      refute Identifier.name?("foo\nend\ndefmodule Evil do")
    end

    test "rejects non-string, non-atom values" do
      refute Identifier.name?(nil)
      refute Identifier.name?(42)
      refute Identifier.name?(%{})
    end
  end

  describe "module?/1" do
    test "accepts a well-formed dotted alias" do
      assert Identifier.module?("AshRemote.Backend.Todo")
      assert Identifier.module?("A")
    end

    test "rejects an empty string" do
      refute Identifier.module?("")
    end

    test "rejects a segment starting lowercase" do
      refute Identifier.module?("AshRemote.backend.Todo")
    end

    test "rejects a segment containing a slash (the path-traversal-relevant case)" do
      refute Identifier.module?("AshRemote.Evil/../../../etc/passwd")
      refute Identifier.module?("Evil/tmp/pwned")
    end

    test "rejects a segment that would inject a defmodule/end pair" do
      refute Identifier.module?("Foo do\n  end\n\n  defmodule Bar")
    end

    test "rejects non-string values" do
      refute Identifier.module?(nil)
      refute Identifier.module?(:not_a_string)
    end
  end

  describe "validate_name!/2" do
    test "returns the value unchanged when valid" do
      assert Identifier.validate_name!("title", "field name") == "title"
    end

    test "raises InvalidManifestError naming the context and offending value" do
      error =
        assert_raise InvalidManifestError, fn ->
          Identifier.validate_name!("bad name", "field name")
        end

      assert error.message =~ "field name"
      assert error.message =~ inspect("bad name")
    end
  end

  describe "validate_module!/2" do
    test "returns the value unchanged when valid" do
      assert Identifier.validate_module!("A.B", "module name") == "A.B"
    end

    test "raises InvalidManifestError naming the context and offending value" do
      error =
        assert_raise InvalidManifestError, fn ->
          Identifier.validate_module!("Evil/../../etc/passwd", "module name")
        end

      assert error.message =~ "module name"
      assert error.message =~ "Evil/../../etc/passwd"
    end
  end
end
