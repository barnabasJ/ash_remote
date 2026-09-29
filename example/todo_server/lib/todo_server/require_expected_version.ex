defmodule TodoServer.RequireExpectedVersion do
  @moduledoc "Restrict an online write to the todo version the client displayed."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset =
      case Ash.Changeset.get_argument(changeset, :expected_version) do
        nil -> changeset
        version -> Ash.Changeset.filter(changeset, version: version)
      end

    # Ash's ETS layer checks the filter and writes in separate operations.
    # Serialize this resource's writes per row so the check and write cannot
    # interleave with another update or destroy action on the demo server.
    Ash.Changeset.around_action(changeset, fn changeset, callback ->
      lock = {{__MODULE__, changeset.data.id}, self()}
      :global.trans(lock, fn -> callback.(changeset) end)
    end)
  end
end
