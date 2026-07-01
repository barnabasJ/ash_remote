defmodule AshRemote.Backend.Todo.TitleWithPrefix do
  @moduledoc "Calculation WITH an argument — exercises calc-arg selection over the wire."
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:title]

  @impl true
  def calculate(records, _opts, context) do
    prefix = Map.get(context.arguments, :prefix, "")
    Enum.map(records, fn record -> "#{prefix}#{record.title}" end)
  end
end
