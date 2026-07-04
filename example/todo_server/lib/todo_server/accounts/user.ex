defmodule TodoServer.Accounts.User do
  @moduledoc "The authentication authority: email + password, issuing JWTs."
  use Ash.Resource,
    otp_app: :todo_server,
    domain: TodoServer.Accounts,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  ets do
    private?(false)
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    policy always() do
      authorize_if(always())
    end
  end

  authentication do
    session_identifier(:jti)

    tokens do
      enabled?(true)
      token_resource(TodoServer.Accounts.Token)
      signing_secret(TodoServer.Secrets)
    end

    strategies do
      password :password do
        identity_field(:email)
        hash_provider(AshAuthentication.BcryptProvider)
        sign_in_tokens_enabled?(false)
      end
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :email, :ci_string do
      allow_nil?(false)
      public?(true)
    end

    attribute :hashed_password, :string do
      allow_nil?(false)
      sensitive?(true)
    end
  end

  actions do
    defaults([:read])

    read :get_by_subject do
      description("Get a user by the subject claim in a JWT")
      argument(:subject, :string, allow_nil?: false)
      get?(true)
      prepare(AshAuthentication.Preparations.FilterBySubject)
    end

    read :sign_in_with_password do
      description("Attempt to sign in using an email and password.")
      get?(true)

      argument :email, :ci_string do
        allow_nil?(false)
      end

      argument :password, :string do
        allow_nil?(false)
        sensitive?(true)
      end

      prepare(AshAuthentication.Strategy.Password.SignInPreparation)

      metadata :token, :string do
        description("A JWT that authenticates the user.")
        allow_nil?(false)
      end
    end

    create :register_with_password do
      description("Register a new user with an email and password.")

      argument :email, :ci_string do
        allow_nil?(false)
      end

      argument :password, :string do
        allow_nil?(false)
        constraints(min_length: 8)
        sensitive?(true)
      end

      argument :password_confirmation, :string do
        allow_nil?(false)
        sensitive?(true)
      end

      change(set_attribute(:email, arg(:email)))
      change(AshAuthentication.Strategy.Password.HashPasswordChange)
      change(AshAuthentication.GenerateTokenChange)
      validate(AshAuthentication.Strategy.Password.PasswordConfirmationValidation)

      metadata :token, :string do
        description("A JWT that authenticates the user.")
        allow_nil?(false)
      end
    end
  end

  identities do
    identity :unique_email, [:email] do
      pre_check_with(TodoServer.Accounts)
    end
  end
end
