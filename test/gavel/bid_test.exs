defmodule Gavel.BidTest do
  use ExUnit.Case, async: true
  alias Gavel.Bid

  @now ~U[2026-06-01 12:00:00Z]

  test "new/1 builds a bid with a Decimal amount and defaults" do
    bid = Bid.new(bidder: 7, amount: Decimal.new("10.50"), placed_at: @now)

    assert bid.bidder == 7
    assert Decimal.equal?(bid.amount, Decimal.new("10.50"))
    assert bid.max_amount == nil
    assert bid.placed_at == @now
  end

  test "new/1 coerces a string or integer amount into Decimal" do
    assert Decimal.equal?(Bid.new(bidder: 1, amount: "3", placed_at: @now).amount, Decimal.new(3))
    assert Decimal.equal?(Bid.new(bidder: 1, amount: 3, placed_at: @now).amount, Decimal.new(3))
  end

  test "new/1 stores an optional max_amount as Decimal" do
    bid = Bid.new(bidder: 1, amount: "5", max_amount: "20", placed_at: @now)
    assert Decimal.equal?(bid.max_amount, Decimal.new(20))
  end
end
