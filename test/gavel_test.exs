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

  # Poll a condition for up to retries*10 ms. Runtime timers fire in real time,
  # so we wait rather than assert synchronously.
  defp eventually(fun, retries \\ 200) do
    cond do
      fun.() ->
        :ok

      retries == 0 ->
        flunk("condition was never met")

      true ->
        Process.sleep(10)
        eventually(fun, retries - 1)
    end
  end

  test "a candle auction auto-closes after the final call" do
    now = DateTime.utc_now()

    {:ok, _} =
      Gavel.start_auction(%{
        id: "candle1",
        type: Gavel.Types.Candle,
        notice_at: DateTime.add(now, 200, :millisecond),
        min_delay: 0,
        max_delay: 0
      })

    # Bid is placed before the notice fires, so it is accepted.
    assert {:ok, _} = Gavel.place_bid("candle1", 1, "10")

    eventually(fn -> Gavel.get("candle1").status == :closed end)
    assert {:sold, 1, price} = Gavel.get("candle1").result
    assert Decimal.equal?(price, Decimal.new(10))
  end

  test "a candle stays open during the burn-down window, then closes" do
    now = DateTime.utc_now()

    {:ok, _} =
      Gavel.start_auction(%{
        id: "candle2",
        type: Gavel.Types.Candle,
        notice_at: DateTime.add(now, 100, :millisecond),
        min_delay: 1,
        max_delay: 1
      })

    assert {:ok, _} = Gavel.place_bid("candle2", 1, "10")

    # After the notice fires the hidden close is set but the auction is still open.
    eventually(fn -> Gavel.get("candle2").extra[:secret_close] != nil end)
    assert Gavel.get("candle2").status == :open

    # The 1-second burn-down then closes it.
    eventually(fn -> Gavel.get("candle2").status == :closed end)
    assert {:sold, 1, _} = Gavel.get("candle2").result
  end

  test "a candle recovers its hidden close after a process crash" do
    now = DateTime.utc_now()

    {:ok, _} =
      Gavel.start_auction(%{
        id: "candle3",
        type: Gavel.Types.Candle,
        notice_at: DateTime.add(now, 100, :millisecond),
        min_delay: 2,
        max_delay: 2
      })

    assert {:ok, _} = Gavel.place_bid("candle3", 1, "10")

    # Wait until the notice has fired and the hidden close is persisted.
    eventually(fn -> Gavel.get("candle3").extra[:secret_close] != nil end)

    # Kill the owning process; the DynamicSupervisor restarts it and init/1
    # rehydrates secret_close from the ETS store.
    [{pid, _}] = Registry.lookup(Gavel.Registry, "candle3")
    Process.exit(pid, :kill)
    eventually(fn -> match?([{_, _}], Registry.lookup(Gavel.Registry, "candle3")) end)

    # It still closes correctly off the recovered hidden close.
    # Wrap in try/catch: between the registry entry appearing and the restarted
    # process being fully ready there is a brief window where GenServer.call
    # exits; we treat that as "not yet" and keep polling.
    eventually(fn ->
      try do
        Gavel.get("candle3").status == :closed
      catch
        :exit, _ -> false
      end
    end)

    assert {:sold, 1, _} = Gavel.get("candle3").result
  end
end
