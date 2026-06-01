defmodule Gavel.Generators do
  @moduledoc "StreamData generators for auction property tests."
  import StreamData

  @doc "A positive Decimal amount with up to 2 decimal places, 0.01..99999.99."
  def amount do
    map(integer(1..9_999_999), fn cents ->
      Decimal.div(Decimal.new(cents), Decimal.new(100))
    end)
  end

  @doc "A bidder id (small positive integer keeps collisions likely for tie tests)."
  def bidder, do: integer(1..50)

  @doc "A list of {bidder, amount} pairs, 2..10 entries."
  def bid_pairs do
    list_of(tuple({bidder(), amount()}), min_length: 2, max_length: 10)
  end
end
