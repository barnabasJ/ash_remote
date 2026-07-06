defmodule AshRemote.Protocol do
  @moduledoc """
  Pure functions that build `/rpc/run` and `/rpc/validate` request bodies and
  parse their responses. No HTTP, no Ash — just the wire shape.

  Request identifies an action by `{resource, action}` (the manifest module
  string plus the Ash action name), since the manifest does not serialize an
  opaque RPC name.
  """

  @type request :: %{
          required(:resource) => String.t(),
          required(:action) => String.t() | atom(),
          optional(:fields) => list(),
          optional(:input) => map(),
          optional(:filter) => map(),
          optional(:sort) => String.t(),
          optional(:page) => map(),
          optional(:primary_key) => map(),
          optional(:tenant) => String.t() | atom()
        }

  @doc "Build the JSON body for `/rpc/run`."
  @spec build_run(request()) :: map()
  def build_run(req), do: build(req)

  @doc "Build the JSON body for `/rpc/validate`."
  @spec build_validate(request()) :: map()
  def build_validate(req), do: build(Map.drop(req, [:fields, :page, :sort, :filter]))

  defp build(req) do
    %{
      "resource" => resource_string(Map.fetch!(req, :resource)),
      "action" => to_string(Map.fetch!(req, :action)),
      "fields" => Map.get(req, :fields),
      "input" => Map.get(req, :input),
      "filter" => Map.get(req, :filter),
      "sort" => Map.get(req, :sort),
      "page" => Map.get(req, :page),
      "primary_key" => Map.get(req, :primary_key),
      # R-1: input to Ash multitenancy, never an auth claim — the server must
      # still scope actors to tenants itself (policies), it just no longer
      # has to invent a tenant from thin air. Absent key = old wire shape
      # (backward compatible).
      "tenant" => req |> Map.get(:tenant) |> tenant_string()
    }
    |> reject_nils()
  end

  defp tenant_string(nil), do: nil
  defp tenant_string(tenant) when is_binary(tenant), do: tenant
  defp tenant_string(tenant), do: to_string(tenant)

  @doc """
  Parse a `/rpc/run` response.

  Returns `{:ok, data}` on success (data may be a list, a map, `nil`, or a
  paginated `%{"results" => ..., "count" => ..., "type" => ...}` map), or
  `{:error, errors}` with the raw wire error list.
  """
  @spec parse_run(map()) :: {:ok, term()} | {:error, [map()]}
  def parse_run(%{"success" => true, "data" => data}), do: {:ok, data}
  def parse_run(%{"success" => true}), do: {:ok, nil}
  def parse_run(%{"success" => false, "errors" => errors}), do: {:error, errors}
  def parse_run(other), do: {:error, [%{"type" => "framework", "message" => inspect(other)}]}

  @doc "Parse a `/rpc/validate` response into `:ok` or `{:error, errors}`."
  @spec parse_validate(map()) :: :ok | {:error, [map()]}
  def parse_validate(%{"success" => true}), do: :ok
  def parse_validate(%{"success" => false, "errors" => []}), do: :ok
  def parse_validate(%{"success" => false, "errors" => errors}), do: {:error, errors}
  def parse_validate(other), do: {:error, [%{"type" => "framework", "message" => inspect(other)}]}

  # Module atoms render without the `Elixir.` prefix, matching the manifest's
  # `resource.module` string; already-string identifiers pass through.
  defp resource_string(mod) when is_atom(mod), do: inspect(mod)
  defp resource_string(str) when is_binary(str), do: str

  defp reject_nils(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end
end
