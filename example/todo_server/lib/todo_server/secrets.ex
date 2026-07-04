defmodule TodoServer.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        TodoServer.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:todo_server, :token_signing_secret)
  end
end
