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

  test "tick lowers the price by decrement, not below floor" do
    a = dutch()
    {:ok, a, [{:price_dropped, _}]} = Dutch.tick(a, @now)
    assert Decimal.equal?(a.extra.price, Decimal.new(90))

    a =
      Enum.reduce(1..10, a, fn _, acc ->
        {:ok, acc, _} = Dutch.tick(acc, @now)
        acc
      end)

    assert Decimal.equal?(a.extra.price, Decimal.new(50))
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
end
