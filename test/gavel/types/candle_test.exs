defmodule Gavel.Types.CandleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Gavel.{Auction, Bid}
  alias Gavel.Generators
  alias Gavel.Types.{Candle, Helpers}

  @now ~U[2026-06-01 12:00:00Z]
  @notice ~U[2026-06-01 12:10:00Z]

  defp valid_config(extra \\ %{}) do
    Map.merge(%{id: "c1", type: Candle, notice_at: @notice, max_delay: 30}, extra)
  end

  defp open_auction(config \\ %{}) do
    {:ok, a} = Auction.new(valid_config(config))
    Auction.open(a, @now)
  end

  describe "kind/0" do
    test "is :open" do
      assert Candle.kind() == :open
    end
  end

  describe "validate_config/1" do
    test "accepts a config with notice_at and max_delay" do
      assert :ok = Candle.validate_config(valid_config())
    end

    test "accepts an optional min_delay" do
      assert :ok = Candle.validate_config(valid_config(%{min_delay: 5}))
    end

    test "rejects a missing notice_at" do
      assert {:error, :missing_notice_at} =
               Candle.validate_config(%{type: Candle, max_delay: 30})
    end

    test "rejects a non-DateTime notice_at" do
      assert {:error, :missing_notice_at} =
               Candle.validate_config(%{type: Candle, notice_at: "soon", max_delay: 30})
    end

    test "rejects a missing max_delay" do
      assert {:error, :missing_max_delay} =
               Candle.validate_config(%{type: Candle, notice_at: @notice})
    end

    test "rejects a negative max_delay" do
      assert {:error, :negative_delay} = Candle.validate_config(valid_config(%{max_delay: -1}))
    end

    test "rejects a negative min_delay" do
      assert {:error, :negative_delay} = Candle.validate_config(valid_config(%{min_delay: -1}))
    end

    test "rejects a non-integer min_delay" do
      assert {:error, :negative_delay} = Candle.validate_config(valid_config(%{min_delay: "5"}))
    end

    test "rejects min_delay greater than max_delay" do
      assert {:error, :min_delay_above_max} =
               Candle.validate_config(valid_config(%{min_delay: 40, max_delay: 30}))
    end
  end

  describe "place_bid/3" do
    defp bid(auction, bidder, amount, secs \\ 0) do
      b = Bid.new(bidder: bidder, amount: amount, placed_at: DateTime.add(@now, secs, :second))
      auction.type.place_bid(auction, b, b.placed_at)
    end

    test "delegates to English: first bid accepted, then a higher bid outbids" do
      {:ok, a, _} = bid(open_auction(), 1, "10")
      {:ok, a, events} = bid(a, 2, "12", 1)
      assert [{:bid_placed, _}, {:outbid, %{bidder: 1}}] = events
      assert Decimal.equal?(Helpers.highest(a.bids).amount, Decimal.new(12))
    end

    test "delegates to English: min_increment is enforced" do
      a = open_auction(%{min_increment: Decimal.new(5)})
      {:ok, a, _} = bid(a, 1, "10")
      assert {:error, :below_min_increment} = bid(a, 2, "12", 1)
    end

    test "accepts bids before the hidden close" do
      a = %{open_auction() | extra: %{secret_close: DateTime.add(@now, 100, :second)}}
      assert {:ok, _a, [{:bid_placed, _} | _]} = bid(a, 1, "10", 10)
    end

    test "rejects bids at or after the hidden close" do
      a = %{open_auction() | extra: %{secret_close: DateTime.add(@now, 100, :second)}}
      assert {:error, :auction_closed} = bid(a, 1, "10", 100)
      assert {:error, :auction_closed} = bid(a, 1, "10", 101)
    end
  end

  describe "on_notice/3" do
    test "sets secret_close to notice_at + delay and emits final_call" do
      a = open_auction(%{max_delay: 30})
      {:ok, a, events} = Candle.on_notice(a, 12, @now)
      assert a.extra.secret_close == DateTime.add(@notice, 12, :second)
      assert [{:final_call, %{notice_at: @notice, max_delay: 30}}] = events
    end

    test "a zero delay closes the window exactly at notice_at" do
      a = open_auction()
      {:ok, a, _} = Candle.on_notice(a, 0, @now)
      assert a.extra.secret_close == @notice
    end
  end
end
