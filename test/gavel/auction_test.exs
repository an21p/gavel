defmodule Gavel.AuctionTest do
  use ExUnit.Case, async: true
  alias Gavel.{Auction, Bid}

  # Minimal stub format for lifecycle tests.
  defmodule StubType do
    @behaviour Gavel.Type
    @impl true
    def kind, do: :open
    @impl true
    def validate_config(%{bad: true}), do: {:error, :bad_config}
    def validate_config(_), do: :ok
    @impl true
    def place_bid(auction, bid, _now), do: {:ok, Auction.put_bid(auction, bid), [{:bid_placed, %{bid: bid}}]}
    @impl true
    def resolve(auction, _now), do: {:ok, %{auction | result: :no_sale}, [{:closed, %{result: :no_sale}}]}
  end

  defmodule SealedStub do
    @behaviour Gavel.Type
    @impl true
    def kind, do: :sealed
    @impl true
    def validate_config(_), do: :ok
    @impl true
    def place_bid(auction, bid, _now), do: {:ok, Auction.put_bid(auction, bid), []}
    @impl true
    def resolve(auction, _now), do: {:ok, auction, []}
  end

  @now ~U[2026-06-01 12:00:00Z]

  test "new/1 builds a pending auction" do
    assert {:ok, auction} = Auction.new(%{id: "a1", type: StubType})
    assert auction.id == "a1"
    assert auction.status == :pending
    assert auction.bids == []
  end

  test "new/1 surfaces config validation errors" do
    assert {:error, :bad_config} = Auction.new(%{id: "a1", type: StubType, bad: true})
  end

  test "open/2 marks the auction open and records timestamps" do
    {:ok, auction} = Auction.new(%{id: "a1", type: StubType, closes_at: ~U[2026-06-01 13:00:00Z]})
    auction = Auction.open(auction, @now)
    assert auction.status == :open
    assert auction.opened_at == @now
    assert auction.closes_at == ~U[2026-06-01 13:00:00Z]
  end

  test "put_bid/2 appends a bid" do
    {:ok, auction} = Auction.new(%{id: "a1", type: StubType})
    bid = Bid.new(bidder: 1, amount: "5", placed_at: @now)
    auction = Auction.put_bid(auction, bid)
    assert auction.bids == [bid]
  end

  test "dump/1 then load/1 round-trips a struct with bids" do
    {:ok, auction} = Auction.new(%{id: "a1", type: StubType})
    auction = auction |> Auction.open(@now) |> Auction.put_bid(Bid.new(bidder: 1, amount: "5", placed_at: @now))

    reloaded = auction |> Auction.dump() |> Auction.load()

    assert reloaded.id == auction.id
    assert reloaded.status == :open
    assert [%Bid{bidder: 1}] = reloaded.bids
    assert Decimal.equal?(hd(reloaded.bids).amount, Decimal.new(5))
  end

  test "new/1 sets phase :bidding for sealed types" do
    assert {:ok, %Auction{phase: :bidding}} = Auction.new(%{id: "s1", type: SealedStub})
  end

  test "open?/1 reflects status" do
    {:ok, auction} = Auction.new(%{id: "a1", type: StubType})
    refute Auction.open?(auction)
    assert Auction.open?(Auction.open(auction, @now))
  end

  test "dump/1 then load/1 round-trips extra (MapSet + Decimal), phase, and a sold result" do
    {:ok, auction} = Auction.new(%{id: "s1", type: SealedStub})

    auction = %{
      auction
      | extra: %{price: Decimal.new("12.50"), active: MapSet.new([1, 2, 3])},
        result: {:sold, 2, Decimal.new("12.50")}
    }

    reloaded = auction |> Auction.dump() |> Auction.load()

    assert reloaded.phase == :bidding
    assert Decimal.equal?(reloaded.extra.price, Decimal.new("12.50"))
    assert MapSet.equal?(reloaded.extra.active, MapSet.new([1, 2, 3]))
    assert {:sold, 2, price} = reloaded.result
    assert Decimal.equal?(price, Decimal.new("12.50"))
  end
end
