defmodule Gavel.Types.Sealed do
  @moduledoc """
  Shared engine for all sealed-bid auction formats.

  This module is not a `Gavel.Type` implementation itself — it provides the
  two pipeline functions (`place_bid/3` and `resolve/3`) that the concrete
  sealed formats delegate to:

  - `Gavel.Types.Vickrey` — highest wins, pays second-highest price
  - `Gavel.Types.SealedFirstPrice` — highest wins, pays own bid
  - `Gavel.Types.Reverse` — lowest wins, pays own bid (procurement)

  ## Sealed-bid mechanics

  All sealed formats share the same bidding rule: **a bidder's most recent
  submission replaces any earlier one**. Bids are not revealed to other
  participants while the auction is open. The winner and price are
  determined at resolve time by a `pricing` function supplied by each
  concrete type.

  ## Delegating to this module

  A concrete type calls `Sealed.place_bid/3` directly from its own
  `place_bid/3` callback, and calls `Sealed.resolve/3` from its `resolve/2`
  callback, supplying a `rank` function (e.g. `&Helpers.ranked_desc/1`) and a
  `pricing` function that maps `(ranked_bids, reserve) -> result`:

  ```elixir
  # From Gavel.Types.Vickrey:
  def resolve(auction, _now) do
    Sealed.resolve(auction, &Helpers.ranked_desc/1, &price/2)
  end
  ```

  ## Events emitted

  | Event | When |
  |-------|------|
  | `{:bid_placed, %{bidder: bidder}}` | A bid is accepted (note: amount is NOT disclosed) |
  | `{:closed, %{result: result}}` | The auction is resolved |
  """

  alias Gavel.{Auction, Bid}
  alias Gavel.Types.Helpers

  @doc """
  Accepts a sealed bid while the auction is open, replacing any prior bid by
  the same bidder.

  The bidder's identity is included in the emitted event but the amount is
  intentionally withheld to preserve the sealed nature of the auction.

  ## Parameters

  - `auction` — the current `Gavel.Auction.t()`.
  - `bid` — the incoming `Gavel.Bid.t()`.
  - `_now` — unused; present for callback-signature compatibility.

  Returns `{:ok, updated_auction, events}` on success, or
  `{:error, :auction_closed}` if the auction is not open.
  """
  def place_bid(%Auction{} = auction, %Bid{} = bid, _now) do
    with :ok <- Helpers.ensure_open(auction) do
      bids = Enum.reject(auction.bids, &(&1.bidder == bid.bidder)) ++ [bid]
      {:ok, %{auction | bids: bids}, [{:bid_placed, %{bidder: bid.bidder}}]}
    end
  end

  @doc """
  Resolves the auction by ranking bids with `rank` and computing the outcome
  with `pricing`.

  The `rank` function receives the raw bid list and must return it sorted
  best-first for the given format (e.g. descending for buyer auctions,
  ascending for procurement). The `pricing` function receives `(ranked_bids,
  reserve)` and returns a `Gavel.Type.result()` — either
  `{:sold, bidder, price}` or `:no_sale`.

  Regardless of outcome the auction's `status` is set to `:closed` and
  `phase` to `:resolved`.

  ## Parameters

  - `auction` — the current `Gavel.Auction.t()`.
  - `rank` — `([Bid.t()] -> [Bid.t()])` — a ranking function.
  - `pricing` — `([Bid.t()], Decimal.t() | nil) -> result` — a pricing function.

  Always returns `{:ok, closed_auction, [{:closed, %{result: result}}]}`.
  """
  def resolve(%Auction{} = auction, rank, pricing) do
    ranked = rank.(auction.bids)
    result = pricing.(ranked, Helpers.reserve(auction))

    {:ok, %{auction | status: :closed, phase: :resolved, result: result},
     [{:closed, %{result: result}}]}
  end
end
