defmodule Gavel.ServerTest do
  use ExUnit.Case, async: false
  alias Gavel.{Auction, Server, Store}
  alias Gavel.Types.Helpers

  setup do
    :ok = Store.ETS.init([])
    on_exit(fn -> :ets.delete_all_objects(:gavel_auctions) end)
    :ok
  end

  defp start_english(id) do
    {:ok, auction} =
      Auction.new(%{id: id, type: Gavel.Types.English, min_increment: Decimal.new(1)})

    {:ok, pid} = Server.start_link(auction: Auction.open(auction, DateTime.utc_now()))
    pid
  end

  defp start_dutch(id) do
    {:ok, auction} =
      Auction.new(%{
        id: id,
        type: Gavel.Types.Dutch,
        start_price: Decimal.new(100),
        floor_price: Decimal.new(50),
        decrement: Decimal.new(50),
        tick_interval_ms: 20
      })

    {:ok, pid} = Server.start_link(auction: Auction.open(auction, DateTime.utc_now()))
    pid
  end

  test "a Dutch clock that reaches the floor with no taker resolves to no_sale" do
    pid = start_dutch("srv_dutch_floor")

    # Clock: 100 -> 50 (floor, one tick) -> 50 (stalled tick closes). At 20ms a
    # tick, this is well settled within 300ms.
    Process.sleep(300)

    auction = Server.get(pid)
    assert auction.status == :closed
    assert auction.result == :no_sale
  end

  test "place_bid records a bid and get returns current state" do
    pid = start_english("srv1")
    assert {:ok, _} = Server.place_bid(pid, bidder: 1, amount: "10")
    assert {:ok, _} = Server.place_bid(pid, bidder: 2, amount: "12")
    auction = Server.get(pid)
    assert Decimal.equal?(Helpers.highest(auction.bids).amount, Decimal.new(12))
  end

  test "a rejected bid returns the error and does not mutate state" do
    pid = start_english("srv2")
    assert {:ok, _} = Server.place_bid(pid, bidder: 1, amount: "10")
    assert {:error, :bid_too_low} == Server.place_bid(pid, bidder: 2, amount: "10")
    assert [%{bidder: 1}] = Server.get(pid).bids
  end

  test "close resolves the auction" do
    pid = start_english("srv3")
    {:ok, _} = Server.place_bid(pid, bidder: 1, amount: "10")
    {:ok, auction} = Server.close(pid)
    assert {:sold, 1, _} = auction.result
  end

  test "state is persisted to the store after each bid" do
    pid = start_english("srv4")
    {:ok, _} = Server.place_bid(pid, bidder: 1, amount: "10")
    assert {:ok, dumped} = Store.ETS.load("srv4")
    assert [%{bidder: 1}] = dumped.bids
  end

  test "a restarted server rehydrates from the store" do
    pid = start_english("srv5")
    {:ok, _} = Server.place_bid(pid, bidder: 1, amount: "10")
    GenServer.stop(pid)

    {:ok, fresh} = Auction.new(%{id: "srv5", type: Gavel.Types.English})
    {:ok, pid2} = Server.start_link(auction: Auction.open(fresh, DateTime.utc_now()))
    auction = Server.get(pid2)
    assert [%{bidder: 1}] = auction.bids
  end

  test "an anti-snipe bid re-arms the close timer so the auction outlives its original deadline" do
    now = DateTime.utc_now()
    original_close = DateTime.add(now, 600, :millisecond)

    {:ok, auction} =
      Auction.new(%{
        id: "srv6",
        type: Gavel.Types.English,
        min_increment: Decimal.new(1),
        closes_at: original_close,
        anti_snipe: %{window: 10, extend_by: 30}
      })

    {:ok, pid} = Server.start_link(auction: Auction.open(auction, now))

    # Bid lands well inside the 10s window, so closes_at is pushed out by 30s.
    {:ok, bid_state} = Server.place_bid(pid, bidder: 1, amount: "10")
    assert DateTime.compare(bid_state.closes_at, original_close) == :gt

    # Wait past the ORIGINAL deadline. If the stale timer were still armed the
    # auction would already be closed; the re-armed timer must keep it open.
    Process.sleep(900)
    assert Server.get(pid).status == :open
  end
end
