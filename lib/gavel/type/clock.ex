defmodule Gavel.Type.Clock do
  @moduledoc """
  Companion behaviour for clock-driven auction formats — those whose
  `c:Gavel.Type.kind/0` returns `:clock`.

  It formalizes the price-clock contract that the base `Gavel.Type` behaviour
  deliberately leaves out, because only some formats have a moving price:

    * `start_clock/1` seeds the clock state (e.g. the starting price, and any
      participant set) once, right after the auction is opened.
    * `tick/2` advances the clock at a given time, moving the price and emitting
      the resulting events.

  `Gavel.Types.Dutch` (descending clock) and `Gavel.Types.Japanese` (ascending
  clock) implement both this behaviour and `Gavel.Type`. The runtime
  (`Gavel.Server`) relies on this contract: for any auction whose `kind/0` is
  `:clock` it calls `start_clock/1` at startup and drives `tick/2` from the
  `:tick` timer. Non-clock formats (English, sealed) do not implement it.

  ## Example

  ```elixir
  defmodule MyApp.ReverseDutch do
    @behaviour Gavel.Type
    @behaviour Gavel.Type.Clock

    @impl Gavel.Type
    def kind, do: :clock

    @impl Gavel.Type.Clock
    def start_clock(auction), do: put_in(auction.extra[:price], auction.config.start_price)

    @impl Gavel.Type.Clock
    def tick(auction, _now), do: {:ok, auction, []}

    # ... the rest of the Gavel.Type callbacks ...
  end
  ```
  """

  alias Gavel.Auction

  @doc """
  Seeds the auction's clock state.

  Called once by the runtime after the auction is opened (and skipped on
  rehydrate, when the state already exists). Returns the auction with its
  clock-specific `:extra` populated (e.g. `%{price: start_price}` for Dutch, or
  `%{price: start_price, active: MapSet.new()}` for Japanese).
  """
  @callback start_clock(Auction.t()) :: Auction.t()

  @doc """
  Advances the clock at `now`.

  Moves the price one step (down for Dutch, up for Japanese) and returns
  `{:ok, updated_auction, events}` — typically a single `{:price_dropped, ...}`
  or `{:price_raised, ...}` event. Driven by the runtime's `:tick` timer.
  """
  @callback tick(Auction.t(), now :: DateTime.t()) :: {:ok, Auction.t(), Gavel.Type.events()}
end
