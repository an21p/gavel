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

    test "rejects min_delay greater than max_delay" do
      assert {:error, :min_delay_above_max} =
               Candle.validate_config(valid_config(%{min_delay: 40, max_delay: 30}))
    end
  end
end
