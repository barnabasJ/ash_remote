defmodule AshRemote.Error.Transport do
  @moduledoc """
  R-6: a typed `Ash.Error.Unknown`-class error for backend-down conditions —
  `{:transport_error, reason}` (connection refused/timeout/etc.) and
  `{:http_error, status, body}` (backend reachable but returned an HTTP error
  status). Previously these passed through `AshRemote.DataLayer`'s read/write
  paths as raw, un-wrapped tuples — the one path retry/circuit-breaker logic
  needs a stable `Ash.Error` type to match on, and an opaque tuple surfacing
  from a data-layer callback is itself the kind of thing MDL's `Flush.classify/1`
  (the ash_multi_datalayer LocalOutbox flush-error taxonomy) must be able to
  recognize: this error's `:unknown` class falls to `classify/1`'s `:transient`
  catch-all (retry, then park on exhaustion) — the correct disposition for a
  backend that's merely unreachable right now, as opposed to a `Forbidden`
  wrapped inside a transport response, which classifies `:auth` instead.
  """
  use Splode.Error, fields: [:reason, :status], class: :unknown

  @type t :: %__MODULE__{reason: term(), status: non_neg_integer() | nil}

  @doc "Build a Transport error from a `{:transport_error, reason}` tuple."
  @spec from_transport_error(term()) :: t()
  def from_transport_error(reason), do: exception(reason: reason)

  @doc "Build a Transport error from an `{:http_error, status, body}` tuple."
  @spec from_http_error(non_neg_integer(), term()) :: t()
  def from_http_error(status, body), do: exception(reason: body, status: status)

  @doc """
  Normalizes whatever `AshRemote.DataLayer.request/4` returned in its
  catch-all `{:error, other}` branch — `{:transport_error, reason}` and
  `{:http_error, status, body}` become this typed error; anything else
  passes through unchanged (defensive — a custom `Transport.Config.module`
  could return some other shape).
  """
  @spec normalize(term()) :: term()
  def normalize({:transport_error, reason}), do: from_transport_error(reason)

  def normalize({:http_error, status, body}) when status in [401, 403] do
    Ash.Error.Forbidden.Policy.exception(custom_message: "HTTP #{status}: #{inspect(body)}")
  end

  def normalize({:http_error, status, body}), do: from_http_error(status, body)
  def normalize(other), do: other

  def message(%__MODULE__{status: nil, reason: reason}) do
    "ash_remote transport error: #{inspect(reason)}"
  end

  def message(%__MODULE__{status: status, reason: reason}) do
    "ash_remote backend returned HTTP #{status}: #{inspect(reason)}"
  end
end
