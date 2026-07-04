defmodule TodoServer.Accounts do
  use Ash.Domain,
    otp_app: :todo_server

  resources do
    resource TodoServer.Accounts.Token
    resource TodoServer.Accounts.User
  end
end
