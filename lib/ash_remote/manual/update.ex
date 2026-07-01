defmodule AshRemote.Manual.Update do
  @moduledoc """
  Manual update implementation for generated remote resources.

  Generated update actions declare `manual AshRemote.Manual.Update` so every
  update round-trips to the backend, regardless of whether the client changeset
  has local attribute changes.
  """
  use Ash.Resource.ManualUpdate

  @impl true
  def update(changeset, _opts, _context) do
    AshRemote.DataLayer.remote_update(changeset.resource, changeset)
  end
end
