defmodule Gavel.Types.Sealed do
  @moduledoc """
  Shared logic for sealed-bid formats. A bidder's latest bid replaces any prior
  one. Winner/price selection is delegated to a `pricing` function supplied by
  each concrete type at resolve time.
  """

  alias Gavel.{Auction, Bid}
  alias Gavel.Types.Helpers

  @doc "Accept a hidden bid while open; a bidder's new bid replaces their old one."
  def place_bid(%Auction{} = auction, %Bid{} = bid, _now) do
    with :ok <- Helpers.ensure_open(auction) do
      bids = Enum.reject(auction.bids, &(&1.bidder == bid.bidder)) ++ [bid]
      {:ok, %{auction | bids: bids}, [{:bid_placed, %{bidder: bid.bidder}}]}
    end
  end

  @doc """
  Resolve using a `pricing` fun: `(ranked_bids, reserve) -> result`.
  `ranked_bids` is ordered best-first per the type's `rank` fun.
  """
  def resolve(%Auction{} = auction, rank, pricing) do
    ranked = rank.(auction.bids)
    result = pricing.(ranked, Helpers.reserve(auction))

    {:ok, %{auction | status: :closed, phase: :resolved, result: result},
     [{:closed, %{result: result}}]}
  end
end
