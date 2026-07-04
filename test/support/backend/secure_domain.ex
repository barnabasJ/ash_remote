defmodule AshRemote.Backend.SecureDomain do
  @moduledoc "A second reference domain holding the policy-protected Document."
  use Ash.Domain, extensions: [AshRemote.Rpc], validate_config_inclusion?: false

  resources do
    resource(AshRemote.Backend.Document)
  end

  rpc do
    pub_sub(AshRemote.Backend.Endpoint)

    resource AshRemote.Backend.Document do
      expose(:read)
      expose(:create)
      expose(:update)
      expose(:destroy)
    end
  end
end
