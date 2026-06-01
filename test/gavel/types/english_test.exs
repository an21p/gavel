defmodule Gavel.Types.EnglishTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Gavel.{Auction, Bid}
  alias Gavel.Generators
  alias Gavel.Types.{English, Helpers}

  @now ~U[2026-06-01 12:00:00Z]

  defp open_auction(config \\ %{}) do
    {:ok, a} = Auction.new(Map.merge(%{id: "e1", type: English}, config))
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
    assert Decimal.equal?(Helpers.highest(a.bids).amount, Decimal.new(12))
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
    {:ok, a, [{:closed, _}]} = English.resolve(a, @now)
    assert {:sold, 2, price} = a.result
    assert Decimal.equal?(price, Decimal.new(20))
  end

  test "resolve below reserve yields :no_sale" do
    a = open_auction(%{reserve_price: Decimal.new(50)})
    {:ok, a, _} = bid(a, 1, "20")
    {:ok, a, _} = English.resolve(a, @now)
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

      {:ok, a, _} = English.resolve(a, @now)
      ranked = Helpers.ranked_desc(a.bids)
      top = hd(ranked)
      assert {:sold, winner, price} = a.result
      assert winner == top.bidder
      assert Decimal.equal?(price, top.amount)
    end
  end

  defp proxy(auction, bidder, max, secs \\ 0) do
    b =
      Bid.new(
        bidder: bidder,
        amount: max,
        max_amount: max,
        placed_at: DateTime.add(@now, secs, :second)
      )

    auction.type.place_bid(auction, b, b.placed_at)
  end

  describe "proxy/max bidding" do
    test "a lone proxy bidder leads at the starting amount, not their max" do
      a = open_auction(%{min_increment: Decimal.new(1), start_price: Decimal.new(10)})
      {:ok, a, _} = proxy(a, 1, "100")
      leader = Helpers.highest(a.bids)
      assert leader.bidder == 1
      assert Decimal.equal?(leader.amount, Decimal.new(10))
    end

    test "the higher max wins, paying one increment above the runner-up's max" do
      a = open_auction(%{min_increment: Decimal.new(5), start_price: Decimal.new(10)})
      {:ok, a, _} = proxy(a, 1, "80")
      {:ok, a, _} = proxy(a, 2, "100", 1)
      leader = Helpers.highest(a.bids)
      assert leader.bidder == 2
      assert Decimal.equal?(leader.amount, Decimal.new(85))
    end

    test "a proxy never exceeds its own max" do
      a = open_auction(%{min_increment: Decimal.new(5), start_price: Decimal.new(10)})
      {:ok, a, _} = proxy(a, 1, "100")
      {:ok, a, _} = proxy(a, 2, "98", 1)
      leader = Helpers.highest(a.bids)
      assert leader.bidder == 1
      # one increment above 98 would be 103 > 100, so capped at the leader's max
      assert Decimal.equal?(leader.amount, Decimal.new(100))
    end
  end
end
