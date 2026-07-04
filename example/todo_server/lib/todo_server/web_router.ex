defmodule TodoServer.WebRouter do
  @moduledoc """
  HTTP surface: token issuance (`/auth/register`, `/auth/sign-in`) plus the
  ash_remote RPC routes, which run behind `TodoServer.AuthPlug` so every action
  executes as the authenticated user.
  """
  use Plug.Router

  plug(:match)
  plug(TodoServer.AuthPlug)
  plug(:dispatch)

  post "/auth/register" do
    %{"email" => email, "password" => password} = conn.params

    register(%{email: email, password: password, password_confirmation: password})
    |> respond(conn)
  end

  post "/auth/sign-in" do
    %{"email" => email, "password" => password} = conn.params
    sign_in(email, password) |> respond(conn)
  end

  forward("/", to: TodoServer.RpcRouter)

  # --- auth helpers --------------------------------------------------------

  defp register(attrs) do
    TodoServer.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, attrs)
    |> Ash.create(authorize?: false)
    |> to_result()
  rescue
    _ -> :error
  end

  defp sign_in(email, password) do
    TodoServer.Accounts.User
    |> Ash.Query.for_read(:sign_in_with_password, %{email: email, password: password})
    |> Ash.read_one(authorize?: false)
    |> to_result()
  rescue
    _ -> :error
  end

  defp to_result({:ok, user}) when not is_nil(user), do: {:ok, user}
  defp to_result(_), do: :error

  defp respond({:ok, user}, conn) do
    body = %{
      "token" => Ash.Resource.get_metadata(user, :token),
      "user" => %{"id" => user.id, "email" => to_string(user.email)}
    }

    send_json(conn, 200, body)
  end

  defp respond(:error, conn), do: send_json(conn, 401, %{"error" => "invalid_credentials"})

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
