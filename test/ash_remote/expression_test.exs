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
            "if true, do: 1",
            "%{a: today}",
            "due_date < today(1)"
          ] do
        refute Expression.safe?(code), "expected unsafe: #{code}"
      end
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
