defmodule Gavel.Types.DutchTest do
  use ExUnit.Case, async: true
  alias Gavel.{Auction, Bid}
  alias Gavel.Types.Dutch

  @now ~U[2026-06-01 12:00:00Z]

  defp dutch(config \\ %{}) do
    base = %{
      id: "d1",
      type: Dutch,
      start_price: Decimal.new(100),
      floor_price: Decimal.new(50),
      decrement: Decimal.new(10)
    }

    {:ok, a} = Auction.new(Map.merge(base, config))
    Dutch.start_clock(Auction.open(a, @now))
  end

  defp accept(auction, bidder, secs \\ 0) do
    b = Bid.new(bidder: bidder, amount: 0, placed_at: DateTime.add(@now, secs, :second))
    auction.type.place_bid(auction, b, b.placed_at)
  end

  test "clock starts at start_price" do
    assert Decimal.equal?(dutch().extra.price, Decimal.new(100))
  end

  test "tick lowers the price by decrement while above the floor" do
    a = dutch()
    {:ok, a, [{:price_dropped, %{price: p}}]} = Dutch.tick(a, @now)
    assert Decimal.equal?(a.extra.price, Decimal.new(90))
    assert Decimal.equal?(p, Decimal.new(90))
    assert a.status == :open
  end

  test "the tick that reaches the floor closes the auction as no_sale" do
    # 100 -> 90 -> 80 -> 70 -> 60, then the 5th tick would compute 50 (the floor)
    # and must close immediately with no :price_dropped event.
    a =
      Enum.reduce(1..4, dutch(), fn _, acc ->
        {:ok, acc, [{:price_dropped, _}]} = Dutch.tick(acc, @now)
        acc
      end)

    assert Decimal.equal?(a.extra.price, Decimal.new(60))

    {:ok, closed, events} = Dutch.tick(a, @now)
    assert events == [{:closed, %{result: :no_sale}}]
    assert closed.status == :closed
    assert closed.result == :no_sale
    assert Decimal.equal?(closed.extra.price, Decimal.new(50))
  end

  test "the first acceptance wins at the current clock price and closes" do
    a = dutch()
    {:ok, a, _} = Dutch.tick(a, @now)
    {:ok, a, [{:closed, _}]} = accept(a, 7)
    assert {:sold, 7, price} = a.result
    assert Decimal.equal?(price, Decimal.new(90))
    assert a.status == :closed
  end

  test "an acceptance after close is rejected" do
    a = dutch()
    {:ok, a, _} = accept(a, 7)
    assert {:error, :auction_closed} = accept(a, 8, 1)
  end

  test "resolve with no acceptance is no_sale" do
    {:ok, a, _} = Dutch.resolve(dutch(), @now)
    assert a.result == :no_sale
  end

  test "rejects :reserve_price as an unsupported option (Dutch uses :floor_price)" do
    config = %{
      id: "d_reserve",
      type: Dutch,
      start_price: Decimal.new(100),
      floor_price: Decimal.new(50),
      decrement: Decimal.new(10),
      reserve_price: Decimal.new(60)
    }

    assert {:error, :unsupported_option} = Auction.new(config)
    assert {:error, :unsupported_option} = Dutch.validate_config(config)
  end
end
