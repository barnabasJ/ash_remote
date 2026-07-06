defmodule TodoClient.BumpVersion do
  @moduledoc """
  Client-authored monotonic `version` for conflict detection. On create the row
  starts at 1; on update it increments from the row's current value. Because the
  CLIENT owns the counter (the server stores it verbatim — see `TodoServer.Todo`),
  a LocalOutbox stale-check can predict its own version chain: an offline
  create→update→destroy is v1→v2→v3, and each flush's `base_image.version` matches
  the server's stored value, so nothing false-parks. A *peer's* write advances the
  server's copy past what this client expects, which is a genuine conflict.

  Wired onto both the local-first (`Local.Todo`) and cache (`Remote.Todo`) mirrors
  so the version advances no matter which strategy made the edit.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    next =
      case changeset.action_type do
        :create -> 1
        :update -> (changeset.data.version || 0) + 1
        _ -> nil
      end

    if next, do: Ash.Changeset.force_change_attribute(changeset, :version, next), else: changeset
  end
end
