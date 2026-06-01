defmodule Gavel.Types.Reverse do
  @moduledoc """
  Sealed procurement (reverse) auction: the lowest bidder wins and is paid
  their own submitted bid.

  In a reverse auction the roles of buyer and seller are swapped: a buyer
  (the auctioneer) solicits offers from competing suppliers and awards the
  contract to the cheapest qualifying offer. Because suppliers want to win,
  they bid *down* rather than up.

  ## Config keys

  | Key | Type | Required | Description |
  |-----|------|----------|-------------|
  | `:reserve_price` | `Decimal` | No | **Maximum budget (ceiling)** — not a floor as in standard auctions. A lowest bid that still exceeds this ceiling results in `:no_sale`. Absent means no budget cap. |

  Note that the semantics of `:reserve_price` are inverted compared to buyer
  auctions: here it is an upper bound on what the buyer is willing to pay,
  not a lower bound on what they will accept.

  ## Lifecycle

  1. Build and open the auction: `Gavel.Auction.new/1` → `Gavel.Auction.open/2`.
  2. Collect sealed bids via `place_bid/3`. Each supplier may revise their
     offer any number of times; only the most recent submission counts.
  3. Call `resolve/2` to close and award the contract.

  No `start_clock/1` or `tick/2` is needed — this is a sealed format.

  ## Events emitted

  | Event | When |
  |-------|------|
  | `{:bid_placed, %{bidder: bidder}}` | An offer is accepted (amount withheld) |
  | `{:closed, %{result: result}}` | Auction resolves |

  ## Example

  ```elixir
  now = DateTime.utc_now()

  # Buyer has a budget ceiling of 500.
  {:ok, auction} =
    Gavel.Auction.new(%{
      type: Gavel.Types.Reverse,
      reserve_price: Decimal.new("500")
    })

  auction = Gavel.Auction.open(auction, now)

  # Suppliers submit their best prices.
  bid_supplier_a = Gavel.Bid.new(bidder: :supplier_a, amount: Decimal.new("420"), placed_at: now)
  bid_supplier_b = Gavel.Bid.new(bidder: :supplier_b, amount: Decimal.new("390"), placed_at: now)

  {:ok, auction, _} = Gavel.Types.Reverse.place_bid(auction, bid_supplier_a, now)
  {:ok, auction, _} = Gavel.Types.Reverse.place_bid(auction, bid_supplier_b, now)

  {:ok, auction, [{:closed, %{result: result}}]} =
    Gavel.Types.Reverse.resolve(auction, now)

  # result => {:sold, :supplier_b, Decimal.new("390")}
  # Cheapest offer within budget wins.
  ```
  """
  @behaviour Gavel.Type

  alias Gavel.Types.{Helpers, Sealed}

  @impl true
  @doc """
  Returns `:sealed`, indicating offers are hidden until the auction closes.
  """
  def kind, do: :sealed

  @impl true
  @doc """
  Validates the Reverse auction config. All config keys are optional, so this
  always returns `:ok`.
  """
  def validate_config(_), do: :ok

  @impl true
  @doc """
  Accepts a sealed offer, replacing any earlier offer from the same bidder.

  Delegates to `Gavel.Types.Sealed.place_bid/3`. The offer amount is not
  disclosed in the returned event.

  Returns `{:ok, updated_auction, [{:bid_placed, %{bidder: bidder}}]}`, or
  `{:error, :auction_closed}` if the auction is not open.
  """
  def place_bid(auction, bid, now), do: Sealed.place_bid(auction, bid, now)

  @impl true
  @doc """
  Closes the auction and awards the contract to the lowest qualifying offer.

  The lowest offer wins if it does not exceed the `:reserve_price` budget
  ceiling. If the cheapest offer is still above the ceiling, the result is
  `:no_sale`. A `nil` reserve (no ceiling) means any offer qualifies.

  The winner pays their own submitted amount — no price adjustment is made.

  Returns `:no_sale` when there are no offers or all offers exceed the budget.

  Always returns `{:ok, closed_auction, [{:closed, %{result: result}}]}`.
  """
  def resolve(auction, _now), do: Sealed.resolve(auction, &Helpers.ranked_asc/1, &price/2)

  defp price([], _ceiling), do: :no_sale

  defp price([winner | _], ceiling) do
    if within_budget?(winner.amount, ceiling),
      do: {:sold, winner.bidder, winner.amount},
      else: :no_sale
  end

  defp within_budget?(_amount, nil), do: true
  defp within_budget?(amount, ceiling), do: Decimal.compare(amount, ceiling) != :gt
end
