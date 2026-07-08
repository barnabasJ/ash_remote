defmodule AshRemote.CompositePkTest do
  @moduledoc """
  L7-3: `[pk] = Ash.Resource.Info.primary_key(resource)` crashed with
  `MatchError` for any composite (multi-attribute) primary key, in both
  `AshRemote.DataLayer.fetch_remote_calculations/5` (`data_layer.ex:372`)
  and `AshRemote.RemoteCalculation` (`remote_calculation.ex:46,71`). Both now
  key by the FULL primary key (`AshRemote.DataLayer.pk_wire_key/2`) instead,
  working identically for single- and multi-attribute PKs — the same fix
  ash_multi_datalayer's L1 applied to its own aggregate-fold paths.

  `AshRemote.Client.CompositeItem` has a 2-attribute PK (`id` + `tenant`)
  and a `AshRemote.RemoteCalculation`-proxied calc (not prefetched by
  default), so `Ash.load!/3` on an already-fetched record is the "bundled
  fetch" path that reaches the crash site.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshRemote.Backend.TestBackend
  alias AshRemote.Client.CompositeItem

  setup do
    TestBackend.reset!()

    Application.put_env(:ash_remote, :remote_config, %{
      CompositeItem => %{
        base_url: TestBackend.base_url(),
        source: "AshRemote.Backend.CompositeItem"
      }
    })

    on_exit(fn -> Application.delete_env(:ash_remote, :remote_config) end)
    :ok
  end

  test "a bundled remote-calculation fetch works for a composite-PK resource (no MatchError)" do
    item =
      CompositeItem
      |> Ash.Changeset.for_create(:create, %{tenant: "acme", title: "hello"})
      |> Ash.create!()

    # Unfixed: `fetch_remote_calculations/5`'s `[pk] = primary_key(resource)`
    # raises `MatchError` for this 2-attribute (`id` + `tenant`) composite PK.
    [loaded] = Ash.load!([item], :shout_title)
    assert loaded.shout_title == "hello"
  end

  test "a bundle serving MULTIPLE composite-PK records keys each result to its own row" do
    a =
      CompositeItem
      |> Ash.Changeset.for_create(:create, %{tenant: "acme", title: "Alpha"})
      |> Ash.create!()

    b =
      CompositeItem
      |> Ash.Changeset.for_create(:create, %{tenant: "other", title: "Beta"})
      |> Ash.create!()

    # Same tenant string as `a`, different id — proves the lookup key uses
    # the FULL primary key (id + tenant), not just one attribute (a
    # single-attribute key on `tenant` alone would collide between this
    # record and `a`; a single-attribute key on `id` would be fine here but
    # not distinguish `a`/`c` if ids collided across tenants).
    c =
      CompositeItem
      |> Ash.Changeset.for_create(:create, %{tenant: "acme", title: "Gamma"})
      |> Ash.create!()

    [loaded_a, loaded_b, loaded_c] = Ash.load!([a, b, c], :shout_title)

    assert loaded_a.shout_title == "Alpha"
    assert loaded_b.shout_title == "Beta"
    assert loaded_c.shout_title == "Gamma"
  end
end
