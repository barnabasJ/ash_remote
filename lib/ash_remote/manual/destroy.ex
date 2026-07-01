defmodule AshRemote.Manual.Destroy do
  @moduledoc "Manual destroy implementation for generated remote resources."
  use Ash.Resource.ManualDestroy

  @impl true
  def destroy(changeset, _opts, _context) do
    AshRemote.DataLayer.remote_destroy(changeset.resource, changeset)
  end
end
