defmodule TodoClient.Remote.Priority do
  use Ash.Type.Enum, values: [:low, :medium, :high]
end
