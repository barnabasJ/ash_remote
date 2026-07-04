defmodule TodoClient.CurrentUser do
  @moduledoc """
  A lightweight local actor carrying the signed-in user's JWT in metadata.
  Passing it as `actor:` lets `AshRemote.DataLayer` auto-forward the token as a
  Bearer header on every RPC — including Ash's relationship-load follow-up reads,
  which the actor propagates to but a bare `context:` would not.
  """
  defstruct [:id, :email, __metadata__: %{}]

  def new(%{"id" => id, "email" => email}, token) do
    %__MODULE__{id: id, email: email, __metadata__: %{token: token}}
  end

  def new(_user, _token), do: nil
end
