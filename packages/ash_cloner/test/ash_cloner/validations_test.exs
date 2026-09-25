defmodule AshCloner.ValidationsTest do
  use ExUnit.Case, async: true

  alias AshCloner.Validations

  describe "sugar/2" do
    test "renders a builtin tuple as its Builtins call" do
      assert {:ok, "string_length(:title, min: 3)"} =
               Validations.sugar("Ash.Resource.Validation.StringLength",
                 attribute: :title,
                 min: 3
               )
    end

    test "renders one_of" do
      assert {:ok, "one_of(:status, [:draft, :published])"} =
               Validations.sugar("Ash.Resource.Validation.OneOf",
                 attribute: :status,
                 values: [:draft, :published]
               )
    end

    test "refuses opts the builtin call would not reproduce" do
      # one_of/2 only takes the attribute and values — an extra opt can't
      # round-trip through the call, so sugar rendering would be lossy.
      assert :error =
               Validations.sugar("Ash.Resource.Validation.OneOf",
                 attribute: :status,
                 values: [:draft, :published],
                 mystery: true
               )
    end

    test "refuses non-builtin modules" do
      assert :error = Validations.sugar("MyApp.CustomValidation", attribute: :title)
    end
  end

  describe "identity/1" do
    test "sugar and tuple spellings share an identity" do
      sugar = Sourceror.parse_string!("validate string_length(:title, min: 3)")

      tuple =
        Sourceror.parse_string!(
          "validate {Ash.Resource.Validation.StringLength, [min: 3, attribute: :title]}"
        )

      assert {:ok, identity} = Validations.identity(sugar)
      assert {:ok, ^identity} = Validations.identity(tuple)
    end

    test "option order does not matter" do
      a = Sourceror.parse_string!("validate string_length(:title, min: 3, max: 10)")
      b = Sourceror.parse_string!("validate string_length(:title, max: 10, min: 3)")

      assert Validations.identity(a) == Validations.identity(b)
    end

    test "different validations differ" do
      a = Sourceror.parse_string!("validate string_length(:title, min: 3)")
      b = Sourceror.parse_string!("validate string_length(:title, min: 4)")

      assert {:ok, left} = Validations.identity(a)
      assert {:ok, right} = Validations.identity(b)
      refute left == right
    end

    test "on/message options are part of the identity" do
      plain = Sourceror.parse_string!("validate string_length(:title, min: 3)")

      on_create =
        Sourceror.parse_string!("validate string_length(:title, min: 3), on: [:create]")

      assert {:ok, left} = Validations.identity(plain)
      assert {:ok, right} = Validations.identity(on_create)
      refute left == right
    end

    test "unsafe AST is refused" do
      dangerous = Sourceror.parse_string!(~s{validate File.rm!("boom")})
      assert :error = Validations.identity(dangerous)
    end

    test "non-validate statements are refused" do
      assert :error = Validations.identity(Sourceror.parse_string!("attribute :title, :string"))
    end
  end
end
