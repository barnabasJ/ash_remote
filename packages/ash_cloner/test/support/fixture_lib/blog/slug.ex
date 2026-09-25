defmodule AshClonerFixtures.Blog.Slug do
  @moduledoc "A plain (non-Ash) helper module the cloner copies verbatim."

  def slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
  end
end
