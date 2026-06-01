defmodule Gavel.Types.SealedFirstPrice do
  @moduledoc """
  Sealed-bid first-price auction: the highest bidder wins and pays their own
  submitted bid.

  This is the classical "silent auction" format. Because winners pay their own
  bid, participants typically shade their bids below their true valuation,
  making the equilibrium bid strategy more complex than in a Vickrey auction.
  Bids are hidden from all participants until `resolve/2` is called.

  ## Config keys

  | Key | Type | Required | Description |
  |-----|------|----------|-------------|
  | `:reserve_price` | `Decimal` | No | Minimum acceptable winning price. If the highest bid is below the reserve the result is `:no_sale`. |

  ## Lifecycle

  1. Build and open the auction: `Gavel.Auction.new/1` → `Gavel.Auction.open/2`.
  2. Collect sealed bids via `place_bid/3`. Each bidder may revise their bid
     any number of times; only the most recent submission counts.
  3. Call `resolve/2` to close and determine the winner.

  No `start_clock/1` or `tick/2` is needed — this is a sealed format.

  ## Events emitted

  | Event | When |
  |-------|------|
  | `{:bid_placed, %{bidder: bidder}}` | A bid is accepted (amount withheld) |
  | `{:closed, %{result: result}}` | Auction resolves |

  ## Example

  ```elixir
  now = DateTime.utc_now()

  {:ok, auction} =
    Gavel.Auction.new(%{
      type: Gavel.Types.SealedFirstPrice,
      reserve_price: Decimal.new("50")
    })

  auction = Gavel.Auction.open(auction, now)

  bid_alice = Gavel.Bid.new(bidder: :alice, amount: Decimal.new("180"), placed_at: now)
  bid_bob   = Gavel.Bid.new(bidder: :bob,   amount: Decimal.new("150"), placed_at: now)

  {:ok, auction, _} = Gavel.Types.SealedFirstPrice.place_bid(auction, bid_alice, now)
  {:ok, auction, _} = Gavel.Types.SealedFirstPrice.place_bid(auction, bid_bob, now)

  {:ok, auction, [{:closed, %{result: result}}]} =
    Gavel.Types.SealedFirstPrice.resolve(auction, now)

  # result => {:sold, :alice, Decimal.new("180")}
  # Alice wins and pays her own bid.
  ```
  """
  @behaviour Gavel.Type

  alias Gavel.Types.{Helpers, Sealed}

  @impl true
  @doc """
  Returns `:sealed`, indicating bids are hidden until the auction closes.
  """
  def kind, do: :sealed

  @impl true
  @doc """
  Validates the SealedFirstPrice config. All config keys are optional, so this
  always returns `:ok`.
  """
  def validate_config(_), do: :ok

  @impl true
  @doc """
  Accepts a sealed bid, replacing any earlier bid from the same bidder.

  Delegates to `Gavel.Types.Sealed.place_bid/3`. The bid amount is not
  disclosed in the returned event.

  Returns `{:ok, updated_auction, [{:bid_placed, %{bidder: bidder}}]}`, or
  `{:error, :auction_closed}` if the auction is not open.
  """
  def place_bid(auction, bid, now), do: Sealed.place_bid(auction, bid, now)

  @impl true
  @doc """
  Closes the auction and determines the winner using first-price rules.

  The highest bidder wins if their amount meets or exceeds the reserve price.
  The price paid is the winner's own submitted bid amount — no second-price
  adjustment is made.

  Returns `:no_sale` when there are no bids or the highest bid is below the
  reserve.

  Always returns `{:ok, closed_auction, [{:closed, %{result: result}}]}`.
  """
  def resolve(auction, _now), do: Sealed.resolve(auction, &Helpers.ranked_desc/1, &price/2)

  defp price([], _reserve), do: :no_sale

  defp price([winner | _], reserve) do
    if Helpers.clears_reserve?(winner.amount, reserve),
      do: {:sold, winner.bidder, winner.amount},
      else: :no_sale
  end
end
