defmodule Gavel.Types.JapaneseTest do
  use ExUnit.Case, async: true
  alias Gavel.{Auction, Bid}
  alias Gavel.Types.Japanese

  @now ~U[2026-06-01 12:00:00Z]

  defp japanese(config \\ %{}) do
    base = %{id: "j1", type: Japanese, start_price: Decimal.new(10), increment: Decimal.new(5)}
    {:ok, a} = Auction.new(Map.merge(base, config))
    Japanese.start_clock(Auction.open(a, @now))
  end

  defp join(auction, bidder, secs \\ 0) do
    price = auction.extra.price
    b = Bid.new(bidder: bidder, amount: price, placed_at: DateTime.add(@now, secs, :second))
    auction.type.place_bid(auction, b, b.placed_at)
  end

  test "bidders join the active set" do
    a = japanese()
    {:ok, a, _} = join(a, 1)
    {:ok, a, _} = join(a, 2, 1)
    assert MapSet.equal?(a.extra.active, MapSet.new([1, 2]))
  end

  test "tick raises the price" do
    a = japanese()
    {:ok, a, _} = join(a, 1)
    {:ok, a, [{:price_raised, _}]} = Japanese.tick(a, @now)
    assert Decimal.equal?(a.extra.price, Decimal.new(15))
  end

  test "last bidder standing wins at the current clock price" do
    a = japanese()
    {:ok, a, _} = join(a, 1)
    {:ok, a, _} = join(a, 2, 1)
    # price 15
    {:ok, a, _} = Japanese.tick(a, @now)
    # price 20
    {:ok, a, _} = Japanese.tick(a, @now)
    {:ok, a, [{:closed, _}]} = Japanese.drop_out(a, 1, @now)
    assert {:sold, 2, price} = a.result
    assert Decimal.equal?(price, Decimal.new(20))
    assert a.status == :closed
  end

  test "dropping a non-participant errors" do
    a = japanese()
    {:ok, a, _} = join(a, 1)
    assert {:error, :not_active} = Japanese.drop_out(a, 99, @now)
  end

  test "resolve with one active bidder sells to them at current price" do
    a = japanese()
    {:ok, a, _} = join(a, 1)
    {:ok, a, _} = Japanese.resolve(a, @now)
    assert {:sold, 1, price} = a.result
    assert Decimal.equal?(price, Decimal.new(10))
  end

  test "resolve with no active bidders is no_sale" do
    {:ok, a, _} = Japanese.resolve(japanese(), @now)
    assert a.result == :no_sale
  end

  test "rejects :reserve_price as an unsupported option (Japanese has no reserve)" do
    config = %{
      id: "j_reserve",
      type: Japanese,
      start_price: Decimal.new(10),
      increment: Decimal.new(5),
      reserve_price: Decimal.new(20)
    }

    assert {:error, :unsupported_option} = Auction.new(config)
    assert {:error, :unsupported_option} = Japanese.validate_config(config)
  end
end
