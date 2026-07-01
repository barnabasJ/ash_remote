defmodule AshRemote.FormatterTest do
  use ExUnit.Case, async: true

  alias AshRemote.Formatter

  test ":none is identity" do
    assert Formatter.format_key(:user_id, :none) == "user_id"
    assert Formatter.parse_key("user_id", :none) == "user_id"
    assert Formatter.format_keys(%{"user_id" => 1}, :none) == %{"user_id" => 1}
  end

  test ":camel round-trips snake_case" do
    assert Formatter.format_key(:user_id, :camel) == "userId"
    assert Formatter.format_key("comment_count", :camel) == "commentCount"
    assert Formatter.parse_key("userId", :camel) == "user_id"
  end

  test ":camel formats nested keys deeply" do
    value = %{"user_id" => "x", "nested" => [%{"created_at" => 1}]}

    assert Formatter.format_keys(value, :camel) == %{
             "userId" => "x",
             "nested" => [%{"createdAt" => 1}]
           }
  end
end
