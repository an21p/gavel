defmodule GavelTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> :ets.delete_all_objects(:gavel_auctions) end)
    :ok
  end

  test "an English auction runs end-to-end through the public API" do
    {:ok, _pid} =
      Gavel.start_auction(%{id: "pub1", type: Gavel.Types.English, min_increment: Decimal.new(1)})

    assert {:ok, _} = Gavel.place_bid("pub1", 1, "10")
    assert {:ok, _} = Gavel.place_bid("pub1", 2, "12")
    assert {:error, :bid_too_low} = Gavel.place_bid("pub1", 3, "12")

    {:ok, auction} = Gavel.close("pub1")
    assert {:sold, 2, price} = auction.result
    assert Decimal.equal?(price, Decimal.new(12))
  end

  test "start_auction raises on invalid config" do
    assert_raise ArgumentError, fn ->
      Gavel.start_auction(%{id: "bad", type: Gavel.Types.Dutch})
    end
  end

  test "a Dutch auction sells via accept/2" do
    {:ok, _} =
      Gavel.start_auction(%{
        id: "pub2",
        type: Gavel.Types.Dutch,
        start_price: Decimal.new(100),
        floor_price: Decimal.new(50),
        decrement: Decimal.new(10)
      })

    assert {:ok, auction} = Gavel.accept("pub2", 7)
    assert {:sold, 7, price} = auction.result
    assert Decimal.equal?(price, Decimal.new(100))
  end
end
