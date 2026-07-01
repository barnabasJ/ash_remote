defmodule Mob.Socket do
  @moduledoc """
  Stand-in for the real `mob` framework's socket. Holds screen state in
  `assigns`, mirroring the LiveView-style API mob screens use.
  """
  defstruct assigns: %{}

  @type t :: %__MODULE__{assigns: map()}

  def new(assigns \\ %{}), do: %__MODULE__{assigns: Map.new(assigns)}

  def assign(%__MODULE__{assigns: assigns} = socket, key, value) do
    %{socket | assigns: Map.put(assigns, key, value)}
  end

  def assign(%__MODULE__{assigns: assigns} = socket, kvs) do
    %{socket | assigns: Enum.into(kvs, assigns)}
  end
end

defmodule Mob.Screen do
  @moduledoc """
  Faithful stand-in for `Mob.Screen` from the real `mob` framework.

  Real mob screens are GenServers rendering native SwiftUI/Jetpack Compose;
  here the same callback surface (`mount/3`, `render/1`, `handle_info/2`) runs
  headlessly on the BEAM so the data integration can be driven and tested
  without an emulator. The `~MOB` template is returned verbatim (the real
  framework parses and binds it to native views on-device).

  Swap this module for `{:mob, "~> 0.7"}` and the screens below run unchanged.
  """
  @callback mount(params :: map(), session :: map(), Mob.Socket.t()) :: {:ok, Mob.Socket.t()}
  @callback render(assigns :: map()) :: binary()
  @callback handle_info(message :: term(), Mob.Socket.t()) :: {:noreply, Mob.Socket.t()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Mob.Screen
      import Mob.Screen, only: [sigil_MOB: 2, tap: 1]
    end
  end

  @doc "The `~MOB` template sigil (uppercase → returned verbatim, like `~H` shape)."
  defmacro sigil_MOB(term, _modifiers), do: term

  @doc "Event value for `on_tap={tap(:event)}` bindings."
  def tap(event), do: {:tap, event}

  # --- headless driver (test/dev only; real mob owns the GenServer lifecycle) ---

  @doc "Mount a screen headlessly, returning its socket."
  def mount(module, params \\ %{}, session \\ %{}) do
    {:ok, socket} = module.mount(params, session, %Mob.Socket{})
    socket
  end

  @doc "Deliver a message to a screen's `handle_info/2`, returning the new socket."
  def dispatch(module, socket, message) do
    {:noreply, socket} = module.handle_info(message, socket)
    socket
  end

  @doc "Render a screen's current assigns to its `~MOB` template string."
  def render(module, socket), do: module.render(socket.assigns)
end
