defmodule AshRemote.RpcPublicationsTest do
  use ExUnit.Case, async: true

  import Spark.Test, only: [assert_dsl_error: 2]

  alias AshRemote.PubSubFixture.{Domain, Widget}
  alias AshRemote.Rpc.Info

  describe "publications/1 precedence" do
    test "publishes (exposed ∪ publish) ∖ no_publish" do
      assert Enum.sort(Info.publications(Domain)) ==
               Enum.sort([{Widget, :update}, {Widget, :internal_touch}])
    end

    test "no_publish beats an exposed action" do
      # :create is exposed but also no_publish'd
      refute Info.publication?(Domain, Widget, :create)
    end

    test "no_publish beats publish for the same action" do
      # :bar_touch is both publish'd and no_publish'd
      refute Info.publication?(Domain, Widget, :bar_touch)
    end

    test "publish opts an unexposed action in" do
      assert Info.publication?(Domain, Widget, :internal_touch)
    end

    test "an exposed-and-not-opted-out action is published" do
      assert Info.publication?(Domain, Widget, :update)
    end

    test "an unrelated action is not published" do
      refute Info.publication?(Domain, Widget, :destroy)
    end
  end

  describe "pub_sub/1" do
    test "is nil when no pub_sub is declared" do
      assert Info.pub_sub(Domain) == nil
    end
  end

  describe "ValidatePublish verifier" do
    test "publish naming an unknown action is a DslError" do
      err =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule BadPublishDomain do
            use Ash.Domain, extensions: [AshRemote.Rpc], validate_config_inclusion?: false

            resources do
            end

            rpc do
              resource AshRemote.PubSubFixture.Widget do
                publish(:nope)
              end
            end
          end
        end

      assert err.message =~ "publish references unknown action :nope"
    end

    test "no_publish naming an unknown action is a DslError" do
      err =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule BadNoPublishDomain do
            use Ash.Domain, extensions: [AshRemote.Rpc], validate_config_inclusion?: false

            resources do
            end

            rpc do
              resource AshRemote.PubSubFixture.Widget do
                expose(:update)
                no_publish(:nope)
              end
            end
          end
        end

      assert err.message =~ "no_publish references unknown action :nope"
    end
  end
end
