defmodule Gavel.Types.SealedTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Gavel.{Auction, Bid}
  alias Gavel.Generators
  alias Gavel.Types.{Helpers, Reverse, SealedFirstPrice, Vickrey}

  @now ~U[2026-06-01 12:00:00Z]

  defp sealed(type, config \\ %{}) do
    {:ok, a} = Auction.new(Map.merge(%{id: "s1", type: type}, config))
    Auction.open(a, @now)
  end

  defp bid(auction, bidder, amount, secs \\ 0) do
    b = Bid.new(bidder: bidder, amount: amount, placed_at: DateTime.add(@now, secs, :second))
    auction.type.place_bid(auction, b, b.placed_at)
  end

  describe "sealed bidding (shared)" do
    test "any number of bids are accepted while open, hidden from each other" do
      a = sealed(Vickrey)
      {:ok, a, _} = bid(a, 1, "10")
      {:ok, a, _} = bid(a, 2, "20", 1)
      assert length(a.bids) == 2
    end

    test "a second bid by the same bidder replaces the first" do
      a = sealed(Vickrey)
      {:ok, a, _} = bid(a, 1, "10")
      {:ok, a, _} = bid(a, 1, "15", 1)
      assert [%Bid{bidder: 1, amount: amt}] = a.bids
      assert Decimal.equal?(amt, Decimal.new(15))
    end
  end

  describe "Vickrey" do
    test "highest wins, pays the second-highest bid" do
      a = sealed(Vickrey)
      {:ok, a, _} = bid(a, 1, "30")
      {:ok, a, _} = bid(a, 2, "50", 1)
      {:ok, a, _} = bid(a, 3, "40", 2)
      {:ok, a, _} = Vickrey.resolve(a, @now)
      assert {:sold, 2, price} = a.result
      assert Decimal.equal?(price, Decimal.new(40))
    end

    test "below reserve ⇒ no_sale" do
      a = sealed(Vickrey, %{reserve_price: Decimal.new(100)})
      {:ok, a, _} = bid(a, 1, "30")
      {:ok, a, _} = Vickrey.resolve(a, @now)
      assert a.result == :no_sale
    end

    test "single bidder pays the reserve when set" do
      a = sealed(Vickrey, %{reserve_price: Decimal.new(25)})
      {:ok, a, _} = bid(a, 1, "40")
      {:ok, a, _} = Vickrey.resolve(a, @now)
      assert {:sold, 1, price} = a.result
      assert Decimal.equal?(price, Decimal.new(25))
    end
  end

  describe "SealedFirstPrice" do
    test "highest wins, pays their own bid" do
      a = sealed(SealedFirstPrice)
      {:ok, a, _} = bid(a, 1, "30")
      {:ok, a, _} = bid(a, 2, "50", 1)
      {:ok, a, _} = SealedFirstPrice.resolve(a, @now)
      assert {:sold, 2, price} = a.result
      assert Decimal.equal?(price, Decimal.new(50))
    end
  end

  describe "Reverse (procurement)" do
    test "lowest wins, pays their own bid" do
      a = sealed(Reverse)
      {:ok, a, _} = bid(a, 1, "30")
      {:ok, a, _} = bid(a, 2, "50", 1)
      {:ok, a, _} = bid(a, 3, "20", 2)
      {:ok, a, _} = Reverse.resolve(a, @now)
      assert {:sold, 3, price} = a.result
      assert Decimal.equal?(price, Decimal.new(20))
    end

    test "reserve is a ceiling: lowest bid above the max budget ⇒ no_sale" do
      a = sealed(Reverse, %{reserve_price: Decimal.new(10)})
      {:ok, a, _} = bid(a, 1, "30")
      {:ok, a, _} = Reverse.resolve(a, @now)
      assert a.result == :no_sale
    end
  end

  property "Vickrey winner pays exactly the second-highest distinct-bidder amount" do
    check all(pairs <- Generators.bid_pairs(), length(Enum.uniq_by(pairs, &elem(&1, 0))) >= 2) do
      a = sealed(Vickrey)

      a =
        pairs
        |> Enum.with_index()
        |> Enum.reduce(a, fn {{bidder, amount}, i}, acc ->
          {:ok, acc, _} =
            acc.type.place_bid(
              acc,
              Bid.new(bidder: bidder, amount: amount, placed_at: DateTime.add(@now, i, :second)),
              DateTime.add(@now, i, :second)
            )

          acc
        end)

      {:ok, a, _} = Vickrey.resolve(a, @now)
      ranked = Helpers.ranked_desc(a.bids)
      [_winner, second | _] = ranked
      assert {:sold, _, price} = a.result
      assert Decimal.equal?(price, second.amount)
    end
  end
end
