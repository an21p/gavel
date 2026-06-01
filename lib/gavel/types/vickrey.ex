defmodule Gavel.Types.Vickrey do
  @moduledoc """
  Sealed-bid second-price (Vickrey) auction: the highest bidder wins but pays
  the second-highest bid price (or the reserve, whichever is greater).

  The key incentive property of the Vickrey format is that bidding your true
  valuation is a dominant strategy — there is never a benefit to shading your
  bid up or down. Bids are hidden from all participants until `resolve/2` is
  called.

  ## Config keys

  | Key | Type | Required | Description |
  |-----|------|----------|-------------|
  | `:reserve_price` | `Decimal` | No | Minimum acceptable winning price. If the highest bid is below the reserve the result is `:no_sale`. When the winner is the sole bidder, they pay the reserve (or their own bid if there is no reserve). |

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
      type: Gavel.Types.Vickrey,
      reserve_price: Decimal.new("100")
    })

  auction = Gavel.Auction.open(auction, now)

  bid_alice = Gavel.Bid.new(bidder: :alice, amount: Decimal.new("300"), placed_at: now)
  bid_bob   = Gavel.Bid.new(bidder: :bob,   amount: Decimal.new("200"), placed_at: now)

  {:ok, auction, _} = Gavel.Types.Vickrey.place_bid(auction, bid_alice, now)
  {:ok, auction, _} = Gavel.Types.Vickrey.place_bid(auction, bid_bob, now)

  {:ok, auction, [{:closed, %{result: result}}]} =
    Gavel.Types.Vickrey.resolve(auction, now)

  # result => {:sold, :alice, Decimal.new("200")}
  # Alice wins but pays Bob's bid, not her own.
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
  Validates the Vickrey config. All config keys are optional, so this always
  returns `:ok`.
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
  Closes the auction and determines the winner using second-price rules.

  The highest bidder wins if their amount meets or exceeds the reserve price.
  The price paid is the greater of: the second-highest bid and the reserve
  price. When only one bid was received and a reserve is configured, the sole
  winner pays the reserve; with no reserve they pay their own bid.

  Returns `:no_sale` when there are no bids or the highest bid is below the
  reserve.

  Always returns `{:ok, closed_auction, [{:closed, %{result: result}}]}`.
  """
  def resolve(auction, _now) do
    Sealed.resolve(auction, &Helpers.ranked_desc/1, &price/2)
  end

  defp price([], _reserve), do: :no_sale

  defp price([winner | rest], reserve) do
    if Helpers.clears_reserve?(winner.amount, reserve) do
      second = second_price(rest, reserve, winner)
      {:sold, winner.bidder, second}
    else
      :no_sale
    end
  end

  # Second price = max(second-highest bid, reserve). With no runner-up, falls back to reserve.
  defp second_price([], reserve, winner), do: reserve || winner.amount

  defp second_price([second | _], reserve, _winner) do
    case reserve do
      nil -> second.amount
      r -> if Decimal.compare(second.amount, r) == :gt, do: second.amount, else: r
    end
  end
end
