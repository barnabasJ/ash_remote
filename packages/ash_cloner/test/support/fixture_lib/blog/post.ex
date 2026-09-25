defmodule AshClonerFixtures.Blog.Post do
  @moduledoc """
  A "library-authored" resource: written as real, compilable code in the
  library's own namespace, cloned into user apps by `AshCloner.SourceCloner`.
  """
  use Ash.Resource,
    domain: AshClonerFixtures.Blog.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title, :body, :published_at]
    end

    update :update do
      accept [:title, :body]
    end
  end

  validations do
    validate string_length(:title, min: 3)
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :body, :string, public?: true
    attribute :published_at, :utc_datetime_usec, public?: true
  end

  relationships do
    has_many :comments, AshClonerFixtures.Blog.Comment
  end

  calculations do
    calculate :preview, :string, expr(title)
  end

  aggregates do
    count :comment_count, :comments
  end

  # A plain helper (and this comment) that the cloner must carry over verbatim.
  def preview_length, do: 50
end
