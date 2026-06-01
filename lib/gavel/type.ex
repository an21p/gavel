defmodule Gavel.Type do
  @moduledoc """
  The behaviour every auction format implements.

  `kind/0` tells the lifecycle how to initialise an auction:

    * `:open`   — bids are public; no phase (English)
    * `:sealed` — bids hidden until close; uses `:phase` (Vickrey, sealed first-price, reverse)
    * `:clock`  — price moves on a timer (Dutch, Japanese)

  Functions receive and return `Gavel.Auction` structs and never raise on bad
  bids — they return `{:error, reason}`. `now` is always supplied by the caller.
  """

  alias Gavel.{Auction, Bid}

  @type events :: [{atom(), map()}]
  @type result :: {:sold, bidder :: term(), price :: Decimal.t()} | :no_sale

  @callback kind() :: :open | :sealed | :clock
  @callback validate_config(config :: map()) :: :ok | {:error, term()}
  @callback place_bid(Auction.t(), Bid.t(), now :: DateTime.t()) ::
              {:ok, Auction.t(), events()} | {:error, term()}
  @callback resolve(Auction.t(), now :: DateTime.t()) :: {:ok, Auction.t(), events()}

  @doc "Advance a clock-driven auction. Only `:clock` types implement this."
  @callback tick(Auction.t(), now :: DateTime.t()) :: {:ok, Auction.t(), events()}

  @doc "Withdraw a bidder. Only Japanese implements this."
  @callback drop_out(Auction.t(), bidder :: term(), now :: DateTime.t()) ::
              {:ok, Auction.t(), events()} | {:error, term()}

  @optional_callbacks tick: 2, drop_out: 3
end
