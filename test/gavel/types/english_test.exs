defmodule Gavel.Types.EnglishTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Gavel.{Auction, Bid}
  alias Gavel.Generators

  @now ~U[2026-06-01 12:00:00Z]

  defp open_auction(config \\ %{}) do
    {:ok, a} = Auction.new(Map.merge(%{id: "e1", type: Gavel.Types.English}, config))
    Auction.open(a, @now)
  end

  defp bid(auction, bidder, amount, secs \\ 0) do
    b = Bid.new(bidder: bidder, amount: amount, placed_at: DateTime.add(@now, secs, :second))
    auction.type.place_bid(auction, b, b.placed_at)
  end

  test "first bid is accepted" do
    {:ok, a, events} = bid(open_auction(), 1, "10")
    assert [%Bid{bidder: 1}] = a.bids
    assert [{:bid_placed, _}] = events
  end

  test "a higher bid is accepted and emits outbid for the prior leader" do
    {:ok, a, _} = bid(open_auction(), 1, "10")
    {:ok, a, events} = bid(a, 2, "12", 1)
    assert [{:bid_placed, _}, {:outbid, %{bidder: 1}}] = events
    assert Decimal.equal?(Gavel.Types.Helpers.highest(a.bids).amount, Decimal.new(12))
  end

  test "a bid that does not beat the current high is rejected" do
    {:ok, a, _} = bid(open_auction(), 1, "10")
    assert {:error, :bid_too_low} = bid(a, 2, "10", 1)
  end

  test "min_increment is enforced" do
    a = open_auction(%{min_increment: Decimal.new(5)})
    {:ok, a, _} = bid(a, 1, "10")
    assert {:error, :below_min_increment} = bid(a, 2, "12", 1)
    assert {:ok, _, _} = bid(a, 2, "15", 1)
  end

  test "bids on a closed auction are rejected" do
    a = %{open_auction() | status: :closed}
    assert {:error, :auction_closed} = bid(a, 1, "10")
  end

  test "resolve sells to the highest bidder at their own bid" do
    {:ok, a, _} = bid(open_auction(), 1, "10")
    {:ok, a, _} = bid(a, 2, "20", 1)
    {:ok, a, [{:closed, _}]} = Gavel.Types.English.resolve(a, @now)
    assert {:sold, 2, price} = a.result
    assert Decimal.equal?(price, Decimal.new(20))
  end

  test "resolve below reserve yields :no_sale" do
    a = open_auction(%{reserve_price: Decimal.new(50)})
    {:ok, a, _} = bid(a, 1, "20")
    {:ok, a, _} = Gavel.Types.English.resolve(a, @now)
    assert a.result == :no_sale
  end

  property "the winner is always the highest bid; ties go to the earliest" do
    check all(pairs <- Generators.bid_pairs()) do
      a = open_auction()

      a =
        pairs
        |> Enum.with_index()
        |> Enum.reduce(a, fn {{bidder, amount}, i}, acc ->
          b = Bid.new(bidder: bidder, amount: amount, placed_at: DateTime.add(@now, i, :second))
          # bypass increment rules: we are testing resolve, so append directly
          Auction.put_bid(acc, b)
        end)

      {:ok, a, _} = Gavel.Types.English.resolve(a, @now)
      ranked = Gavel.Types.Helpers.ranked_desc(a.bids)
      top = hd(ranked)
      assert {:sold, winner, price} = a.result
      assert winner == top.bidder
      assert Decimal.equal?(price, top.amount)
    end
  end
end
