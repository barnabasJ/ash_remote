defmodule TodoServer.Priority do
  @moduledoc "Todo priority — an enum, exercising named-type codegen in the client."
  use Ash.Type.Enum, values: [:low, :medium, :high]
end
