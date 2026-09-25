defmodule AshCloner.DefinitionTest do
  use ExUnit.Case, async: true

  alias AshCloner.Definition

  test "new/1 builds from keyword fields" do
    definition =
      Definition.new(
        module: "UserApp.Post",
        kind: :resource,
        source: "defmodule UserApp.Post do\nend\n",
        entities: %{attributes: [{:title, "attribute :title, :string"}]}
      )

    assert %Definition{module: "UserApp.Post", kind: :resource, resources: []} = definition
    assert definition.entities.attributes == [{:title, "attribute :title, :string"}]
  end

  test "new/1 rejects unknown fields" do
    assert_raise KeyError, fn ->
      Definition.new(module: "UserApp.Post", kind: :resource, sources: "typo")
    end
  end
end
