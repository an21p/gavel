defmodule Gavel.Types.Japanese do
  @moduledoc """
  Ascending-clock (Japanese button) auction: the price rises on each tick and
  bidders drop out by releasing their button; the last bidder standing wins at
  the current price.

  Unlike English auctions, bidders must actively *stay in* rather than
  proactively outbid each other. A bidder signals participation by calling
  `place_bid/3` (joining the active set), and signals withdrawal by calling
  `drop_out/3`. The auction closes automatically when only one bidder remains.

  ## Config keys

  | Key | Type | Required | Description |
  |-----|------|----------|-------------|
  | `:start_price` | `Decimal` | Yes | Opening clock price. |
  | `:increment` | `Decimal` | Yes | Amount added to the clock on each `tick/2` call. |

  `validate_config/1` enforces that both keys are `Decimal` structs.

  ## Lifecycle

  1. Build and open the auction: `Gavel.Auction.new/1` → `Gavel.Auction.open/2`.
  2. Call `start_clock/1` to initialise the clock and the active bidder set.
  3. Bidders join by calling `place_bid/3` with an amount ≥ current price.
  4. Advance the clock with `tick/2` (e.g. on a timer).
  5. Bidders who can no longer accept the price call `drop_out/3`. When only
     one remains the auction closes automatically.
  6. If the auction is still open after the last tick cycle, call `resolve/2`
     to settle with the remaining active set.

  ## Events emitted

  | Event | When |
  |-------|------|
  | `{:joined, %{bidder: bidder}}` | A bidder joins the active set |
  | `{:price_raised, %{price: price}}` | Each `tick/2` |
  | `{:dropped, %{remaining: count}}` | A bidder drops out (more than one remain) |
  | `{:closed, %{result: result}}` | Auction closes (last bidder drops out or `resolve/2`) |

  ## Example

  ```elixir
  now = DateTime.utc_now()

  {:ok, auction} =
    Gavel.Auction.new(%{
      type: Gavel.Types.Japanese,
      start_price: Decimal.new("100"),
      increment: Decimal.new("25")
    })

  auction =
    auction
    |> Gavel.Auction.open(now)
    |> Gavel.Types.Japanese.start_clock()

  # Both bidders join at the opening price.
  bid_alice = Gavel.Bid.new(bidder: :alice, amount: Decimal.new("100"), placed_at: now)
  bid_bob   = Gavel.Bid.new(bidder: :bob,   amount: Decimal.new("100"), placed_at: now)

  {:ok, auction, [{:joined, %{bidder: :alice}}]} =
    Gavel.Types.Japanese.place_bid(auction, bid_alice, now)

  {:ok, auction, [{:joined, %{bidder: :bob}}]} =
    Gavel.Types.Japanese.place_bid(auction, bid_bob, now)

  # Clock rises to 125.
  {:ok, auction, [{:price_raised, %{price: _}}]} =
    Gavel.Types.Japanese.tick(auction, now)

  # Bob drops out — Alice is the last bidder, so the auction closes.
  {:ok, auction, [{:closed, %{result: {:sold, :alice, price}}}]} =
    Gavel.Types.Japanese.drop_out(auction, :bob, now)
  ```
  """
  @behaviour Gavel.Type
  @behaviour Gavel.Type.Clock

  alias Gavel.{Auction, Bid}
  alias Gavel.Types.Helpers

  @impl Gavel.Type
  @doc """
  Returns `:clock`, indicating this auction is driven by an ascending price
  timer and requires `start_clock/1` before accepting bids.
  """
  def kind, do: :clock

  @impl Gavel.Type
  @doc """
  Validates that `:start_price` and `:increment` are both `Decimal` structs.

  Returns `:ok` on success, or one of:

  - `{:error, :unsupported_option}` — `:reserve_price` was supplied. Japanese
    auctions have no reserve; the seller's floor is `:start_price` (bidding
    begins there). This is rejected rather than silently ignored.
  - `{:error, :missing_clock_config}` — `:start_price` or `:increment` is
    absent or not a `Decimal`.
  """
  def validate_config(config) do
    cond do
      Map.has_key?(config, :reserve_price) ->
        {:error, :unsupported_option}

      match?(%Decimal{}, Map.get(config, :start_price)) and
          match?(%Decimal{}, Map.get(config, :increment)) ->
        :ok

      true ->
        {:error, :missing_clock_config}
    end
  end

  @doc """
  Initialises the ascending clock and the empty active-bidder set.

  Stores `%{price: start_price, active: MapSet.new()}` in `auction.extra`.
  Must be called once after `Gavel.Auction.open/2` and before the first
  `place_bid/3` or `tick/2`.

  ## Parameters

  - `auction` — an open `Gavel.Auction.t()` with a validated config.

  Returns the updated auction struct.
  """
  @impl Gavel.Type.Clock
  @spec start_clock(Gavel.Auction.t()) :: Gavel.Auction.t()
  def start_clock(%Auction{config: config} = auction) do
    %{auction | extra: %{price: config.start_price, active: MapSet.new()}}
  end

  @impl Gavel.Type
  @doc """
  Adds a bidder to the active set, confirming their participation at the
  current clock price.

  The bid's `amount` must be ≥ the current clock price. A bidder who has
  already joined can rejoin (their entry is idempotent via `MapSet.put/2`).

  ## Events

  Emits `{:joined, %{bidder: bidder}}` on success.

  ## Errors

  - `{:error, :auction_closed}` — the auction is not open.
  - `{:error, :bid_too_low}` — `bid.amount` is less than the current clock price.
  """
  def place_bid(%Auction{} = auction, %Bid{} = bid, _now) do
    with :ok <- Helpers.ensure_open(auction) do
      price = auction.extra.price

      if Decimal.compare(bid.amount, price) == :lt do
        {:error, :bid_too_low}
      else
        active = MapSet.put(auction.extra.active, bid.bidder)
        {:ok, put_active(auction, active), [{:joined, %{bidder: bid.bidder}}]}
      end
    end
  end

  @impl Gavel.Type.Clock
  @doc """
  Advances the clock by adding `:increment` to the current price.

  Emits `{:price_raised, %{price: new_price}}`. Does not automatically remove
  bidders — each bidder must explicitly call `drop_out/3` when they can no
  longer accept the new price.

  Returns `{:ok, updated_auction, events}`.
  """
  def tick(%Auction{} = auction, _now) do
    next = Decimal.add(auction.extra.price, auction.config.increment)
    {:ok, %{auction | extra: %{auction.extra | price: next}}, [{:price_raised, %{price: next}}]}
  end

  @impl Gavel.Type
  @doc """
  Removes a bidder from the active set.

  If removing this bidder leaves exactly one participant, the auction closes
  immediately with that participant as the winner at the current clock price.
  Otherwise emits `{:dropped, %{remaining: count}}` and continues.

  ## Errors

  - `{:error, :auction_closed}` — the auction is not open.
  - `{:error, :not_active}` — `bidder` is not in the current active set (they
    never joined or already dropped out).
  """
  def drop_out(%Auction{} = auction, bidder, _now) do
    with :ok <- Helpers.ensure_open(auction) do
      if MapSet.member?(auction.extra.active, bidder) do
        active = MapSet.delete(auction.extra.active, bidder)
        auction = put_active(auction, active)
        maybe_close(auction, active)
      else
        {:error, :not_active}
      end
    end
  end

  @impl Gavel.Type
  @doc """
  Settles the auction when called explicitly (e.g. after all ticks are
  exhausted).

  If exactly one bidder remains active, they win at the current clock price.
  Any other active-set size (zero or more than one) results in `:no_sale`.

  Always returns `{:ok, closed_auction, [{:closed, %{result: result}}]}`.
  """
  def resolve(%Auction{} = auction, _now) do
    case MapSet.to_list(auction.extra.active) do
      [winner] ->
        close_sold(auction, winner)

      _ ->
        result = :no_sale
        {:ok, %{auction | status: :closed, result: result}, [{:closed, %{result: result}}]}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_close(auction, active) do
    case MapSet.to_list(active) do
      [winner] -> close_sold(auction, winner)
      _ -> {:ok, auction, [{:dropped, %{remaining: MapSet.size(active)}}]}
    end
  end

  defp close_sold(auction, winner) do
    result = {:sold, winner, auction.extra.price}
    {:ok, %{auction | status: :closed, result: result}, [{:closed, %{result: result}}]}
  end

  defp put_active(auction, active), do: %{auction | extra: %{auction.extra | active: active}}
end
