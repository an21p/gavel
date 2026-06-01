defmodule Gavel.CoverageTest do
  @moduledoc """
  Focused tests for branches not covered by the primary test files.
  Targets: Dutch validate_config, Japanese validate_config, English resolve (no bids),
  Reverse within_budget? nil, SealedFirstPrice no bids, Vickrey second-price variants,
  Helpers.meets_increment? / maybe_extend / ranked_asc tie-break,
  Store.DETS delete/all, Gavel facade set_max_bid/drop_out,
  Server handle_info + drop_out + close-already-closed + schedule_tick for clock types.
  """
  use ExUnit.Case, async: false

  alias Gavel.{Auction, Bid, Server, Store}
  alias Gavel.Types.{Dutch, English, Helpers, Japanese, Reverse, SealedFirstPrice, Vickrey}

  @now ~U[2026-06-01 12:00:00Z]

  # ---------------------------------------------------------------------------
  # Dutch validate_config error paths
  # ---------------------------------------------------------------------------

  describe "Dutch.validate_config/1" do
    test "missing clock keys returns :missing_clock_config" do
      assert {:error, :missing_clock_config} = Dutch.validate_config(%{})
    end

    test "floor_price above start_price returns :floor_above_start" do
      config = %{
        start_price: Decimal.new(50),
        floor_price: Decimal.new(100),
        decrement: Decimal.new(5)
      }

      assert {:error, :floor_above_start} = Dutch.validate_config(config)
    end
  end

  # ---------------------------------------------------------------------------
  # Japanese validate_config error path
  # ---------------------------------------------------------------------------

  describe "Japanese.validate_config/1" do
    test "missing clock keys returns :missing_clock_config" do
      assert {:error, :missing_clock_config} = Japanese.validate_config(%{})
    end

    test "partial config (only start_price) returns :missing_clock_config" do
      assert {:error, :missing_clock_config} =
               Japanese.validate_config(%{start_price: Decimal.new(10)})
    end
  end

  # ---------------------------------------------------------------------------
  # English.resolve — no bids → :no_sale
  # ---------------------------------------------------------------------------

  describe "English.resolve/2 no bids" do
    test "resolve with zero bids yields :no_sale" do
      {:ok, a} = Auction.new(%{id: "eng-ns", type: English})
      a = Auction.open(a, @now)
      {:ok, a, [{:closed, %{result: :no_sale}}]} = English.resolve(a, @now)
      assert a.result == :no_sale
    end
  end

  # ---------------------------------------------------------------------------
  # Reverse — within_budget? nil ceiling branch (always true)
  # ---------------------------------------------------------------------------

  describe "Reverse — no reserve (nil ceiling)" do
    test "lowest bid wins even with no reserve set" do
      {:ok, a} = Auction.new(%{id: "rev-nil", type: Reverse})
      a = Auction.open(a, @now)
      b = Bid.new(bidder: 1, amount: "25", placed_at: @now)
      {:ok, a, _} = Reverse.place_bid(a, b, @now)
      {:ok, a, _} = Reverse.resolve(a, @now)
      assert {:sold, 1, price} = a.result
      assert Decimal.equal?(price, Decimal.new(25))
    end

    test "no bids → :no_sale" do
      {:ok, a} = Auction.new(%{id: "rev-nobids", type: Reverse})
      a = Auction.open(a, @now)
      {:ok, a, _} = Reverse.resolve(a, @now)
      assert a.result == :no_sale
    end
  end

  # ---------------------------------------------------------------------------
  # SealedFirstPrice — no bids → :no_sale
  # ---------------------------------------------------------------------------

  describe "SealedFirstPrice.resolve/2 no bids" do
    test "resolve with zero bids yields :no_sale" do
      {:ok, a} = Auction.new(%{id: "sfp-ns", type: SealedFirstPrice})
      a = Auction.open(a, @now)
      {:ok, a, _} = SealedFirstPrice.resolve(a, @now)
      assert a.result == :no_sale
    end
  end

  # ---------------------------------------------------------------------------
  # Vickrey — single-bidder-no-reserve and second_price with reserve > second bid
  # ---------------------------------------------------------------------------

  describe "Vickrey second-price edge cases" do
    test "single bidder with no reserve pays their own bid" do
      {:ok, a} = Auction.new(%{id: "vic-solo", type: Vickrey})
      a = Auction.open(a, @now)
      b = Bid.new(bidder: 1, amount: "50", placed_at: @now)
      {:ok, a, _} = Vickrey.place_bid(a, b, @now)
      {:ok, a, _} = Vickrey.resolve(a, @now)
      assert {:sold, 1, price} = a.result
      assert Decimal.equal?(price, Decimal.new(50))
    end

    test "reserve is larger than second bid: winner pays the reserve" do
      reserve = Decimal.new(40)
      {:ok, a} = Auction.new(%{id: "vic-res", type: Vickrey, reserve_price: reserve})
      a = Auction.open(a, @now)
      b1 = Bid.new(bidder: 1, amount: "80", placed_at: @now)
      b2 = Bid.new(bidder: 2, amount: "30", placed_at: DateTime.add(@now, 1, :second))
      {:ok, a, _} = Vickrey.place_bid(a, b1, @now)
      {:ok, a, _} = Vickrey.place_bid(a, b2, DateTime.add(@now, 1, :second))
      {:ok, a, _} = Vickrey.resolve(a, @now)
      assert {:sold, 1, price} = a.result
      # second bid is 30, reserve is 40 → winner pays 40
      assert Decimal.equal?(price, reserve)
    end

    test "second bid is larger than reserve: winner pays the second bid" do
      reserve = Decimal.new(20)
      {:ok, a} = Auction.new(%{id: "vic-res2", type: Vickrey, reserve_price: reserve})
      a = Auction.open(a, @now)
      b1 = Bid.new(bidder: 1, amount: "80", placed_at: @now)
      b2 = Bid.new(bidder: 2, amount: "50", placed_at: DateTime.add(@now, 1, :second))
      {:ok, a, _} = Vickrey.place_bid(a, b1, @now)
      {:ok, a, _} = Vickrey.place_bid(a, b2, DateTime.add(@now, 1, :second))
      {:ok, a, _} = Vickrey.resolve(a, @now)
      assert {:sold, 1, price} = a.result
      assert Decimal.equal?(price, Decimal.new(50))
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers.meets_increment? all branches
  # ---------------------------------------------------------------------------

  describe "Helpers.meets_increment?/3" do
    test "nil floor, nil min: any positive amount passes" do
      assert Helpers.meets_increment?(Decimal.new(1), nil, nil)
      refute Helpers.meets_increment?(Decimal.new(0), nil, nil)
    end

    test "nil floor, some min: any positive amount passes (min ignored without floor)" do
      assert Helpers.meets_increment?(Decimal.new(1), nil, Decimal.new(5))
    end

    test "has floor, nil min: amount just needs to be strictly greater" do
      assert Helpers.meets_increment?(Decimal.new(11), Decimal.new(10), nil)
      refute Helpers.meets_increment?(Decimal.new(10), Decimal.new(10), nil)
    end

    test "has floor, has min: amount must be at least floor + min" do
      assert Helpers.meets_increment?(Decimal.new(15), Decimal.new(10), Decimal.new(5))
      refute Helpers.meets_increment?(Decimal.new(14), Decimal.new(10), Decimal.new(5))
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers.maybe_extend — bid outside the anti-snipe window (no extension)
  # ---------------------------------------------------------------------------

  describe "Helpers.maybe_extend/2" do
    test "bid well before the anti-snipe window does not extend" do
      closes_at = DateTime.add(@now, 600, :second)

      {:ok, a} =
        Auction.new(%{
          id: "ext-no",
          type: English,
          anti_snipe: %{window: 60, extend_by: 120}
        })

      a = %{Auction.open(a, @now) | closes_at: closes_at}
      {a2, events} = Helpers.maybe_extend(a, @now)
      assert events == []
      assert a2.closes_at == closes_at
    end

    test "auction with nil closes_at is a no-op" do
      {:ok, a} = Auction.new(%{id: "ext-nil", type: English})
      a = Auction.open(a, @now)
      {a2, events} = Helpers.maybe_extend(a, @now)
      assert events == []
      assert a2.closes_at == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers.ranked_asc — tie-break by earliest placed_at
  # ---------------------------------------------------------------------------

  describe "Helpers.ranked_asc/1 tie-break" do
    test "equal amounts: earlier bid ranks first" do
      b1 = Bid.new(bidder: 1, amount: "10", placed_at: @now)
      b2 = Bid.new(bidder: 2, amount: "10", placed_at: DateTime.add(@now, 1, :second))
      [first | _] = Helpers.ranked_asc([b2, b1])
      assert first.bidder == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Store.DETS — delete/1 and all/0
  # ---------------------------------------------------------------------------

  describe "Store.DETS delete and all" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "gavel_cov_#{System.unique_integer([:positive])}.dets")

      :ok = Store.DETS.init(path: path)
      on_exit(fn -> File.rm(path) end)
      :ok
    end

    test "delete/1 removes an entry so load returns :error" do
      :ok = Store.DETS.save("x1", %{id: "x1"})
      {:ok, _} = Store.DETS.load("x1")
      :ok = Store.DETS.delete("x1")
      assert :error = Store.DETS.load("x1")
    end

    test "all/0 returns every saved entry" do
      :ok = Store.DETS.save("a1", %{id: "a1"})
      :ok = Store.DETS.save("a2", %{id: "a2"})
      entries = Store.DETS.all()
      ids = Enum.map(entries, & &1.id) |> Enum.sort()
      assert ids == ["a1", "a2"]
    end
  end

  # ---------------------------------------------------------------------------
  # Gavel public facade — set_max_bid/3 and drop_out/2
  # ---------------------------------------------------------------------------

  describe "Gavel facade" do
    setup do
      :ok = Store.ETS.init([])
      on_exit(fn -> :ets.delete_all_objects(:gavel_auctions) end)
    end

    test "set_max_bid/3 places a proxy bid through the facade" do
      {:ok, _} =
        Gavel.start_auction(%{
          id: "fac-proxy",
          type: English,
          min_increment: Decimal.new(1),
          start_price: Decimal.new(0)
        })

      assert {:ok, _} = Gavel.set_max_bid("fac-proxy", :alice, Decimal.new(100))
      auction = Gavel.get("fac-proxy")
      assert length(auction.bids) == 1
    end

    test "drop_out/2 drops a bidder from a Japanese auction via the facade" do
      {:ok, _} =
        Gavel.start_auction(%{
          id: "fac-drop",
          type: Japanese,
          start_price: Decimal.new(10),
          increment: Decimal.new(5)
        })

      assert {:ok, _} = Gavel.place_bid("fac-drop", :alice, Decimal.new(10))
      assert {:ok, _} = Gavel.place_bid("fac-drop", :bob, Decimal.new(10))
      # alice drops out, bob wins
      assert {:ok, _} = Gavel.drop_out("fac-drop", :alice)
    end
  end

  # ---------------------------------------------------------------------------
  # Server — handle_info :tick, :close, close-already-closed
  # ---------------------------------------------------------------------------

  describe "Server handle_info paths" do
    setup do
      :ok = Store.ETS.init([])
      on_exit(fn -> :ets.delete_all_objects(:gavel_auctions) end)
    end

    test "close on an already-closed auction is a no-op" do
      {:ok, auction} = Auction.new(%{id: "srv-cls2", type: English})
      {:ok, pid} = Server.start_link(auction: Auction.open(auction, @now))
      {:ok, _} = Server.close(pid)
      # second close should still return ok
      assert {:ok, closed} = Server.close(pid)
      assert closed.status == :closed
    end

    test "handle_info(:tick) on a non-open auction is a no-op" do
      {:ok, auction} = Auction.new(%{id: "srv-tick-noop", type: English})
      {:ok, pid} = Server.start_link(auction: Auction.open(auction, @now))
      # close it, then send a stale tick — should not crash
      {:ok, _} = Server.close(pid)
      send(pid, :tick)
      # give it a moment then verify it's still alive
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "handle_info(:close) when already closed is a no-op" do
      {:ok, auction} = Auction.new(%{id: "srv-close-noop", type: English})
      {:ok, pid} = Server.start_link(auction: Auction.open(auction, @now))
      {:ok, _} = Server.close(pid)
      send(pid, :close)
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "handle_info(:close) when open resolves the auction" do
      # Use a Dutch auction with closes_at in the past to trigger the :close path
      closes_at = DateTime.add(@now, -1, :second)

      {:ok, auction} =
        Auction.new(%{
          id: "srv-close-open",
          type: Dutch,
          start_price: Decimal.new(100),
          floor_price: Decimal.new(50),
          decrement: Decimal.new(10),
          closes_at: closes_at
        })

      {:ok, pid} =
        Server.start_link(auction: %{Auction.open(auction, @now) | closes_at: closes_at})

      # The :close timer fires almost immediately (closes_at is in the past).
      # Wait for the server to process it.
      Process.sleep(100)
      closed = Server.get(pid)
      assert closed.status == :closed
    end

    test "Server.drop_out/2 delegates to the type's drop_out callback" do
      {:ok, auction} =
        Auction.new(%{
          id: "srv-drop",
          type: Japanese,
          start_price: Decimal.new(10),
          increment: Decimal.new(5)
        })

      {:ok, pid} = Server.start_link(auction: Auction.open(auction, @now))

      {:ok, _} = Server.place_bid(pid, bidder: :alice, amount: Decimal.new(10))
      {:ok, _} = Server.place_bid(pid, bidder: :bob, amount: Decimal.new(10))
      assert {:ok, _} = Server.drop_out(pid, :alice)
    end

    test "Server.drop_out/2 returns error for unknown bidder" do
      {:ok, auction} =
        Auction.new(%{
          id: "srv-drop-err",
          type: Japanese,
          start_price: Decimal.new(10),
          increment: Decimal.new(5)
        })

      {:ok, pid} = Server.start_link(auction: Auction.open(auction, @now))
      {:ok, _} = Server.place_bid(pid, bidder: :alice, amount: Decimal.new(10))
      # :carol never joined — drop_out should return the type's error
      assert {:error, :not_active} = Server.drop_out(pid, :carol)
    end

    test "handle_info(:tick) on an open clock auction advances the price" do
      # Dutch with a very long tick interval so the timer doesn't fire on its own;
      # we send :tick manually via handle_info
      {:ok, auction} =
        Auction.new(%{
          id: "srv-tick-open",
          type: Dutch,
          start_price: Decimal.new(100),
          floor_price: Decimal.new(50),
          decrement: Decimal.new(10),
          tick_interval_ms: 3_600_000
        })

      {:ok, pid} = Server.start_link(auction: Auction.open(auction, @now))
      send(pid, :tick)
      Process.sleep(50)
      state = Server.get(pid)
      assert Decimal.equal?(state.extra.price, Decimal.new(90))
    end

    test "Server starts a clock auction and schedule_tick arms the timer" do
      # Dutch with a tick_interval_ms — server init should arm a tick timer.
      # We verify via state (the timer is scheduled, price eventually drops on tick).
      {:ok, auction} =
        Auction.new(%{
          id: "srv-sched-tick",
          type: Dutch,
          start_price: Decimal.new(100),
          floor_price: Decimal.new(50),
          decrement: Decimal.new(5),
          tick_interval_ms: 20
        })

      {:ok, pid} = Server.start_link(auction: Auction.open(auction, @now))
      # Wait for at least one tick to fire automatically
      Process.sleep(80)
      state = Server.get(pid)
      assert Decimal.compare(state.extra.price, Decimal.new(100)) == :lt
    end
  end

  # ---------------------------------------------------------------------------
  # Dutch.resolve — already-sold no-op branch (result != nil)
  # ---------------------------------------------------------------------------

  describe "Dutch.resolve/2 already sold" do
    test "resolve when already sold is a no-op" do
      {:ok, a} =
        Auction.new(%{
          id: "dutch-sold",
          type: Dutch,
          start_price: Decimal.new(100),
          floor_price: Decimal.new(50),
          decrement: Decimal.new(10)
        })

      a = Dutch.start_clock(Auction.open(a, @now))
      # Accept at current price to set the result
      b = Bid.new(bidder: 7, amount: 0, placed_at: @now)
      {:ok, a, _} = Dutch.place_bid(a, b, @now)
      assert {:sold, _, _} = a.result
      # resolve on an already-closed/sold auction returns it unchanged
      {:ok, a2, events} = Dutch.resolve(a, @now)
      assert events == []
      assert a2.result == a.result
    end
  end

  # ---------------------------------------------------------------------------
  # Dutch current_price fallback (no extra.price set — reads from config)
  # ---------------------------------------------------------------------------

  describe "Dutch current_price fallback" do
    test "accept before start_clock uses start_price from config" do
      {:ok, a} =
        Auction.new(%{
          id: "dutch-noclk",
          type: Dutch,
          start_price: Decimal.new(200),
          floor_price: Decimal.new(50),
          decrement: Decimal.new(10)
        })

      # Open but deliberately skip start_clock so extra is empty
      a = Auction.open(a, @now)
      b = Bid.new(bidder: 1, amount: 0, placed_at: @now)
      {:ok, a, _} = Dutch.place_bid(a, b, @now)
      assert {:sold, 1, price} = a.result
      assert Decimal.equal?(price, Decimal.new(200))
    end
  end

  # ---------------------------------------------------------------------------
  # English — rank_by_ceiling tie-break (:eq branch)
  # ---------------------------------------------------------------------------

  describe "English rank_by_ceiling tie-break" do
    test "equal-ceiling proxy bids: earlier placed_at leads" do
      {:ok, a} = Auction.new(%{id: "eng-tie", type: English, min_increment: Decimal.new(1)})
      a = Auction.open(a, @now)

      # Two proxy bids with the same max — the earlier one leads
      b1 = Bid.new(bidder: 1, amount: "50", max_amount: "50", placed_at: @now)

      b2 =
        Bid.new(
          bidder: 2,
          amount: "50",
          max_amount: "50",
          placed_at: DateTime.add(@now, 1, :second)
        )

      # Inject both directly (bypassing admissibility checks since ceilings are equal)
      a = %{a | bids: [b1, b2]}
      # Trigger recompute by calling resolve (or place a new bid through the type)
      {:ok, a, _} = English.resolve(a, @now)
      assert {:sold, 1, _} = a.result
    end
  end

  # ---------------------------------------------------------------------------
  # Japanese — maybe_close with multiple active bidders still remaining
  # ---------------------------------------------------------------------------

  describe "Japanese drop_out with multiple remaining" do
    test "dropping with >=2 active bidders remaining does not close" do
      {:ok, a} =
        Auction.new(%{
          id: "jap-multi",
          type: Japanese,
          start_price: Decimal.new(10),
          increment: Decimal.new(5)
        })

      a = Japanese.start_clock(Auction.open(a, @now))
      price = a.extra.price
      b = fn bidder -> Bid.new(bidder: bidder, amount: price, placed_at: @now) end
      {:ok, a, _} = Japanese.place_bid(a, b.(1), @now)
      {:ok, a, _} = Japanese.place_bid(a, b.(2), @now)
      {:ok, a, _} = Japanese.place_bid(a, b.(3), @now)
      {:ok, a, [{:dropped, %{remaining: 2}}]} = Japanese.drop_out(a, 1, @now)
      assert a.status == :open
    end
  end

  # ---------------------------------------------------------------------------
  # Vickrey — no bids (price/2 empty-list clause)
  # ---------------------------------------------------------------------------

  describe "Vickrey no bids" do
    test "resolve with no bids yields :no_sale" do
      {:ok, a} = Auction.new(%{id: "vic-empty", type: Vickrey})
      a = Auction.open(a, @now)
      {:ok, a, _} = Vickrey.resolve(a, @now)
      assert a.result == :no_sale
    end
  end

  # ---------------------------------------------------------------------------
  # Store.DETS — init when table is already open (close-and-reopen branch)
  # ---------------------------------------------------------------------------

  describe "Store.DETS init idempotency" do
    test "calling init twice reuses the same path without crashing" do
      path =
        Path.join(System.tmp_dir!(), "gavel_idem_#{System.unique_integer([:positive])}.dets")

      on_exit(fn -> File.rm(path) end)
      :ok = Store.DETS.init(path: path)
      :ok = Store.DETS.save("z1", %{id: "z1"})
      # Second init on the same process — table is already open, triggers the close branch
      :ok = Store.DETS.init(path: path)
      assert {:ok, %{id: "z1"}} = Store.DETS.load("z1")
    end
  end

  # ---------------------------------------------------------------------------
  # Auction.load — binary :type key and {:dt, s} extra value round-trips
  # ---------------------------------------------------------------------------

  describe "Auction dump/load round-trip edge cases" do
    test "load handles binary type string (as from JSON storage)" do
      {:ok, a} = Auction.new(%{id: "ld-bin", type: English})
      a = Auction.open(a, @now)
      dumped = Auction.dump(a)
      # Simulate a JSON store that kept :type as a binary string
      dumped_with_binary_type = %{
        dumped
        | config: Map.put(dumped.config, :type, "Elixir.Gavel.Types.English")
      }

      loaded = Auction.load(dumped_with_binary_type)
      assert loaded.type == English
    end

    test "load handles {:dt, iso_string} extra values" do
      {:ok, a} = Auction.new(%{id: "ld-dt", type: English})
      a = Auction.open(a, @now)
      # Inject a DateTime into extra so dump produces {:dt, ...}
      a = %{a | extra: %{snapshot: @now}}
      dumped = Auction.dump(a)
      loaded = Auction.load(dumped)
      assert %DateTime{} = loaded.extra.snapshot
    end

    test "load_dt is a no-op for an already-decoded DateTime" do
      # After load, a DateTime-valued field in extra should survive a second load
      {:ok, a} = Auction.new(%{id: "ld-dt2", type: English})
      a = Auction.open(a, @now)
      a = %{a | extra: %{snapshot: @now}}
      dumped = Auction.dump(a)
      loaded = Auction.load(dumped)
      # Dump + load again (simulates double-decode)
      dumped2 = Auction.dump(loaded)
      loaded2 = Auction.load(dumped2)
      assert %DateTime{} = loaded2.extra.snapshot
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers.ranked_desc tie-break (:eq branch)
  # ---------------------------------------------------------------------------

  describe "Helpers.ranked_desc/1 tie-break" do
    test "equal amounts: earlier bid ranks first" do
      b1 = Bid.new(bidder: 1, amount: "10", placed_at: @now)
      b2 = Bid.new(bidder: 2, amount: "10", placed_at: DateTime.add(@now, 1, :second))
      [first | _] = Helpers.ranked_desc([b2, b1])
      assert first.bidder == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers.maybe_extend — bid outside window (remaining > window_s)
  # ---------------------------------------------------------------------------

  describe "Helpers.maybe_extend outside window" do
    test "bid with remaining > window_s returns no events" do
      closes_at = DateTime.add(@now, 120, :second)

      {:ok, a} =
        Auction.new(%{
          id: "ext-outside",
          type: English,
          anti_snipe: %{window: 30, extend_by: 60}
        })

      a = %{Auction.open(a, @now) | closes_at: closes_at}
      # remaining = 120s, window = 30s → outside → no extension
      {_a, events} = Helpers.maybe_extend(a, @now)
      assert events == []
    end

    test "bid within the anti-snipe window extends closes_at and emits :extended" do
      closes_at = DateTime.add(@now, 15, :second)

      {:ok, a} =
        Auction.new(%{
          id: "ext-inside",
          type: English,
          anti_snipe: %{window: 30, extend_by: 60}
        })

      a = %{Auction.open(a, @now) | closes_at: closes_at}
      # remaining = 15s, window = 30s → inside window → extension fires
      {a2, [{:extended, %{closes_at: new_closes}}]} = Helpers.maybe_extend(a, @now)
      assert DateTime.compare(new_closes, closes_at) == :gt
      assert a2.closes_at == new_closes
    end

    test "anti_snipe config present but wrong shape returns no events" do
      closes_at = DateTime.add(@now, 15, :second)
      # anti_snipe is set but is not a map with :window/:extend_by
      {:ok, a} = Auction.new(%{id: "ext-bad", type: English, anti_snipe: :disabled})
      a = %{Auction.open(a, @now) | closes_at: closes_at}
      {_a, events} = Helpers.maybe_extend(a, @now)
      assert events == []
    end
  end

  # ---------------------------------------------------------------------------
  # English rank_by_ceiling :eq tie-break (two proxy bids with equal max_amount)
  # ---------------------------------------------------------------------------

  describe "English rank_by_ceiling equal-ceiling tie-break" do
    test "equal proxy ceilings: earlier placed_at leads" do
      {:ok, a} = Auction.new(%{id: "eng-eq-ceil", type: English, start_price: Decimal.new(10)})
      a = Auction.open(a, @now)

      b1 = Bid.new(bidder: 1, amount: "50", max_amount: "50", placed_at: @now)

      b2 =
        Bid.new(
          bidder: 2,
          amount: "50",
          max_amount: "50",
          placed_at: DateTime.add(@now, 1, :second)
        )

      # Inject both directly, then resolve to exercise rank_by_ceiling's :eq branch
      a = %{a | bids: [b2, b1]}
      {:ok, a, _} = English.resolve(a, @now)
      assert {:sold, 1, _} = a.result
    end
  end

  # ---------------------------------------------------------------------------
  # Server — pubsub broadcast when :gavel, :pubsub is configured
  # ---------------------------------------------------------------------------

  describe "Server broadcast with pubsub" do
    setup do
      :ok = Store.ETS.init([])
      on_exit(fn -> :ets.delete_all_objects(:gavel_auctions) end)

      # Start a dedicated PubSub for this test; use a unique name to stay isolated.
      pubsub_name = :"GavelTestPubSub#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})
      Application.put_env(:gavel, :pubsub, pubsub_name)
      on_exit(fn -> Application.delete_env(:gavel, :pubsub) end)
      %{pubsub: pubsub_name}
    end

    test "placing a bid broadcasts on phoenix pubsub when configured", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "auction:pub-bcast")

      {:ok, auction} =
        Auction.new(%{id: "pub-bcast", type: English, min_increment: Decimal.new(1)})

      {:ok, pid} = Server.start_link(auction: Auction.open(auction, @now))
      {:ok, _} = Server.place_bid(pid, bidder: 1, amount: "10")

      assert_receive {:gavel, "pub-bcast", {:bid_placed, _}}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Server — schedule_tick fallback clause (non-open auction)
  # ---------------------------------------------------------------------------

  describe "Server schedule_tick fallback" do
    setup do
      :ok = Store.ETS.init([])
      on_exit(fn -> :ets.delete_all_objects(:gavel_auctions) end)
    end

    test "starting a server with an already-closed auction hits schedule_tick fallback" do
      {:ok, auction} = Auction.new(%{id: "srv-closed-start", type: English})
      closed = %{Auction.open(auction, @now) | status: :closed, result: :no_sale}
      # Starting with a closed auction: schedule_tick's fallback (non-open) clause fires
      {:ok, pid} = Server.start_link(auction: closed)
      state = Server.get(pid)
      assert state.status == :closed
    end
  end

  # ---------------------------------------------------------------------------
  # Auction.load_dt — %DateTime{} passthrough (already decoded)
  # ---------------------------------------------------------------------------

  describe "Auction.load/1 with pre-decoded DateTime" do
    test "load_dt is a no-op when opened_at is already a DateTime struct" do
      # Construct a dump-like map where opened_at is already a %DateTime{} (not a string).
      # This simulates reading from a store that kept the raw struct (e.g. in-memory ETS).
      dumped = %{
        id: "ld-dt-pass",
        type: "Elixir.Gavel.Types.English",
        status: :open,
        phase: nil,
        config: %{type: English},
        bids: [],
        opened_at: @now,
        closes_at: nil,
        result: nil,
        extra: %{}
      }

      loaded = Auction.load(dumped)
      assert loaded.opened_at == @now
    end
  end
end
