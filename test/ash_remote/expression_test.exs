defmodule AshRemote.ExpressionTest do
  use ExUnit.Case, async: true

  alias AshRemote.Expression

  defp encode(calc_name) do
    calc = Ash.Resource.Info.calculation(AshRemote.Backend.Todo, calc_name)
    {Ash.Resource.Calculation.Expression, opts} = calc.calculation
    Expression.encode(opts[:expr], AshRemote.Backend.Todo)
  end

  test "encodes a real expression calculation into expr-compatible source" do
    assert {:ok, code} = encode(:is_overdue)
    assert code =~ "due_date < today()"
    assert code =~ "not (completed)"
    assert Expression.safe?(code)
  end

  describe "safe?/1" do
    test "accepts the supported grammar" do
      for code <- [
            "(due_date < today())",
            "(priority in [:high, :low]) and not is_nil(due_date)",
            "(age >= 18) or (name == \"admin\")",
            "(due_date >= ~D[2026-01-01])",
            "not (completed)"
          ] do
        assert Expression.safe?(code), "expected safe: #{code}"
      end
    end

    test "rejects anything outside the grammar" do
      for code <- [
            "File.rm!(\"/etc/passwd\")",
            "fragment(\"1=1\")",
            "author.name == \"x\"",
            "System.cmd(\"rm\", [\"-rf\"])",
            "apply(File, :rm!, [\"x\"])",
            "%{a: today}",
            "due_date < today(1)"
          ] do
        refute Expression.safe?(code), "expected unsafe: #{code}"
      end
    end

    test "accepts if/else — the shape cond do...end desugars to" do
      for code <- [
            "if(due_date < today(), do: :overdue, else: :ok)",
            "if(is_nil(due_date), do: :ok, else: if((due_date < today()), do: :overdue, else: :ok))"
          ] do
        assert Expression.safe?(code), "expected safe: #{code}"
      end
    end

    test "rejects unsafe content hidden inside an if branch" do
      for code <- [
            "if(true, do: File.rm!(\"/etc/passwd\"), else: :ok)",
            "if(author.name == \"x\", do: :ok, else: :ok)",
            "if(true, do: :ok, else: fragment(\"1=1\"))"
          ] do
        refute Expression.safe?(code), "expected unsafe: #{code}"
      end
    end
  end

  describe "encode/2 with if/cond" do
    alias Ash.Query.{Call, Ref}

    defp ref(attribute), do: %Ref{attribute: attribute, relationship_path: []}

    test "encodes a cond-desugared if with a missing :else as nil" do
      # `if due_date < today(), do: :overdue` with no else branch — Ash's own
      # `Ash.Query.Function.If.new/2` defaults a missing `:else` key to `nil`,
      # so the encoder must treat "key absent" the same as "key present with
      # value nil" rather than rejecting it.
      ast = %Call{
        name: :if,
        relationship_path: [],
        args: [
          %Call{
            name: :<,
            relationship_path: [],
            args: [ref(:due_date), %Call{name: :today, relationship_path: [], args: []}]
          },
          [do: :overdue]
        ]
      }

      assert {:ok, code} = Expression.encode(ast, AshRemote.Backend.Todo)
      assert code =~ "do: :overdue"
      assert code =~ "else: nil"
      assert Expression.safe?(code)
    end

    test "encodes nested if calls (a multi-branch cond) recursively" do
      ast = %Call{
        name: :if,
        relationship_path: [],
        args: [
          %Call{name: :is_nil, relationship_path: [], args: [ref(:due_date)]},
          [
            do: :no_due_date,
            else: %Call{
              name: :if,
              relationship_path: [],
              args: [
                %Call{
                  name: :<,
                  relationship_path: [],
                  args: [ref(:due_date), %Call{name: :today, relationship_path: [], args: []}]
                },
                [do: :overdue, else: :ok]
              ]
            }
          ]
        ]
      }

      assert {:ok, code} = Expression.encode(ast, AshRemote.Backend.Todo)
      assert code =~ "is_nil(due_date)"
      assert code =~ "do: :no_due_date"
      assert code =~ "due_date < today()"
      assert Expression.safe?(code)
    end

    test "still refuses to encode a Postgres-only function like lower/1 on a range" do
      # `lower/1`/`upper/1` on a range compile to a raw Postgres SQL function
      # with no defined meaning on another data layer — mirroring them by
      # name would silently collide with SQLite's own string-casing
      # `lower`/`upper` builtins and return wrong values instead of failing
      # loudly, so they must stay unrecognized (falling back to `remote(...)`
      # in the generator), unlike `if`, which has a real `evaluate/1`.
      ast = %Call{name: :lower, relationship_path: [], args: [ref(:due_date)]}

      assert Expression.encode(ast, AshRemote.Backend.Todo) == :error
    end
  end

  test "manifest carries expressions only for mirrorable calculations" do
    {:ok, map} = :ash_remote |> AshRemote.Server.manifest_json() |> Jason.decode()

    todo =
      Enum.find(map["resources"], &(&1["module"] == "AshRemote.Backend.Todo"))

    assert todo["fields"]["is_overdue"]["expression"] =~ "due_date < today()"
    refute Map.has_key?(todo["fields"]["title_with_prefix"], "expression")
  end
end
