defmodule AshRemote.SafeMessageTest do
  @moduledoc """
  R-5 (fix-plan Phase B1-5): `Server.safe_message/1` returned
  `Exception.message/1` for ANY rescued error — an internal (non-Ash)
  exception's message can leak implementation details (module names, argument
  values, stack context) to the client. Only Splode `:invalid`/`:forbidden`
  class messages are safe to expose (covers `Ash.Error.Invalid`, `Forbidden`,
  and every NotFound variant, which are all `:invalid`); everything else
  (critically `:unknown` — what a raised non-Ash exception becomes) must
  become a generic message, with the real exception logged server-side.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias AshRemote.Backend.TestBackend

  @todo "AshRemote.Backend.Todo"

  setup do
    TestBackend.reset!()
    :ok
  end

  test "an internal (non-Ash) error never leaks its message to the client" do
    log =
      capture_log(fn ->
        resp =
          AshRemote.Server.run_action(:ash_remote, %{
            "resource" => @todo,
            "action" => "update",
            # not a map — `fetch!/3`'s `is_map` guard has no fallback clause,
            # so this raises a plain FunctionClauseError deep inside dispatch.
            "primary_key" => "not-a-map",
            "input" => %{}
          })

        assert %{"success" => false, "errors" => [%{"message" => message}]} = resp
        refute message =~ "FunctionClauseError"
        refute message =~ "fetch!"
        assert message =~ ~r/^internal error/
      end)

    assert log =~ "FunctionClauseError"
  end

  test "an Ash.Error.Invalid (required attribute) message still reaches the client" do
    assert %{"success" => false, "errors" => [%{"type" => "required", "message" => message}]} =
             AshRemote.Server.run_action(:ash_remote, %{
               "resource" => @todo,
               "action" => "create",
               "input" => %{}
             })

    assert is_binary(message)
    refute message =~ ~r/^internal error/
  end
end
