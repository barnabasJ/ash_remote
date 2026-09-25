defmodule AshClonerFixtures.Blog.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshClonerFixtures.Blog.Post
    resource AshClonerFixtures.Blog.Comment
  end
end
