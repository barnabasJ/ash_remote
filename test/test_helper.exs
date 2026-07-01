{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = AshRemote.Backend.TestBackend.start()

ExUnit.start()
