defmodule AshRemote.Manifest.AtomSafetyTest do
  @moduledoc """
  R-8 (fix-plan Phase B0-6 / B3-1): `Manifest.Loader.atom/1` minted atoms
  (`String.to_atom/1`) from arbitrary manifest-supplied strings. Ash
  vocabulary atoms (kinds, cardinalities, action types, …) all exist by load
  time, so `String.to_existing_atom/1` is sufficient — but a raw
  `ArgumentError` on a bad manifest is a cryptic failure; the fix must name
  the offending manifest key in a clear error.
  """
  # async: false — an atom-count assertion must not share the VM with other
  # concurrently-running async test processes ticking the same global counter.
  use ExUnit.Case, async: false

  alias AshRemote.Manifest.Loader

  @fixture "test/support/fixtures/manifest.json"

  defp write_garbage_manifest!(mutate) do
    manifest = @fixture |> File.read!() |> Jason.decode!() |> mutate.()

    path =
      Path.join(System.tmp_dir!(), "garbage_manifest_#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(manifest))
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "a garbage field kind never mints an atom and names the offending key" do
    path =
      write_garbage_manifest!(fn manifest ->
        todo_index =
          Enum.find_index(manifest["resources"], &(&1["module"] == "AshRemote.Backend.Todo"))

        update_in(
          manifest,
          ["resources", Access.at(todo_index), "fields", "title", "kind"],
          fn _ -> "not_a_real_ash_kind_#{System.unique_integer([:positive])}" end
        )
      end)

    before_count = :erlang.system_info(:atom_count)

    assert_raise ArgumentError, ~r/fields\.title\.kind/, fn -> Loader.load!(path) end

    # `to_existing_atom/1` never mints regardless of outcome — a strict
    # zero-growth assertion is correct in principle, but the VM's global atom
    # counter can tick from unrelated activity (logger, telemetry) even in an
    # `async: false` test; a small tolerance absorbs that noise without
    # masking the linear-growth bug `String.to_atom/1` would show.
    assert :erlang.system_info(:atom_count) - before_count < 5
  end
end
