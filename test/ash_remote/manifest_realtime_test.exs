defmodule AshRemote.ManifestRealtimeTest do
  @moduledoc "The realtime block in the manifest, its loader normalization, and codegen."
  use ExUnit.Case, async: true

  alias AshRemote.Manifest

  setup_all do
    json = :ash_remote |> AshRemote.Server.manifest_json() |> Jason.decode!()
    {:ok, json: json}
  end

  describe "manifest_json realtime block" do
    test "advertises only deliverable published mutation actions", %{json: json} do
      realtime = json["realtime"]
      assert realtime["topic_prefix"] == "ash_remote"
      assert realtime["socket_path"] == "/ash_remote/socket"

      by_resource =
        Map.new(realtime["subscriptions"], fn s -> {s["resource"], s["actions"]} end)

      assert by_resource["AshRemote.Backend.Todo"] == ["create", "destroy", "update"]
      assert by_resource["AshRemote.Backend.User"] == ["create"]

      # Comment.create is no_publish'd — its only mutation — so it is not advertised.
      refute Map.has_key?(by_resource, "AshRemote.Backend.Comment")
    end
  end

  describe "loader" do
    test "normalizes the realtime block into a resource set", %{json: json} do
      path = Path.join(System.tmp_dir!(), "ash_remote_realtime_manifest.json")
      File.write!(path, Jason.encode!(json))

      manifest = Manifest.Loader.load!(path)

      assert Manifest.realtime?(manifest, "AshRemote.Backend.Todo")
      refute Manifest.realtime?(manifest, "AshRemote.Backend.Comment")
    end

    test "tolerates a manifest with no realtime block" do
      manifest = Manifest.Loader.load!("test/support/fixtures/manifest.json")
      assert manifest.realtime == nil
      refute Manifest.realtime?(manifest, "AshRemote.Backend.Todo")
    end
  end

  describe "generator" do
    test "emits realtime? true only for advertised resources", %{json: json} do
      path = Path.join(System.tmp_dir!(), "ash_remote_realtime_gen_manifest.json")
      File.write!(path, Jason.encode!(json))
      manifest = Manifest.Loader.load!(path)

      modules = AshRemote.Gen.generate(manifest, namespace: "AshRemote.RealtimeGen")
      todo = Enum.find(modules, &(&1.module == "AshRemote.RealtimeGen.Todo"))

      assert todo.source =~ "realtime? true"
    end
  end
end
