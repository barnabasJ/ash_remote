defmodule AshRemote.Client.Todo do
  @moduledoc "Hand-written mirror (M2) of the backend Todo, on AshRemote.DataLayer."
  use Ash.Resource,
    domain: AshRemote.Client.Domain,
    data_layer: AshRemote.DataLayer

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:completed, :boolean, public?: true, default: false, allow_nil?: false)
    attribute(:status, AshRemote.Backend.Todo.Status, public?: true)
    attribute(:priority_score, AshRemote.Backend.PriorityScore, public?: true)
    attribute(:due_date, :date, public?: true)
  end

  relationships do
    belongs_to(:user, AshRemote.Client.User, public?: true, attribute_writable?: true)
    has_many(:comments, AshRemote.Client.Comment, public?: true)
  end

  aggregates do
    count(:comment_count, :comments, public?: true)
  end

  calculations do
    # Stubs — the backend computes these. The placeholder expression must be
    # non-constant (referencing an attribute) so Ash routes it through the data
    # layer (`add_calculation`) instead of constant-folding it locally; the data
    # layer ignores the expression and folds the calc *name* into the RPC.
    calculate :is_overdue, :boolean, expr(completed) do
      public?(true)
    end

    calculate :title_with_prefix, :string, expr(title) do
      public?(true)
      argument(:prefix, :string, allow_nil?: false, default: "")
    end
  end

  actions do
    default_accept([:title, :completed, :status, :priority_score, :due_date, :user_id])

    read(:read, primary?: true)
    create(:create, primary?: true)

    update :update do
      primary?(true)
      require_atomic?(false)
    end

    destroy(:destroy, primary?: true)
  end
end
