defmodule Gavel.Types.Dutch do
  @moduledoc """
  Descending-clock (Dutch) auction: the price drops on each tick and the first
  bidder to accept the current price wins immediately.

  Unlike ascending auctions there is no competitive bidding — the first
  acceptance closes the lot. If the clock reaches the floor price and no one
  has accepted, `resolve/2` records `:no_sale`.

  ## Config keys

  | Key | Type | Required | Description |
  |-----|------|----------|-------------|
  | `:start_price` | `Decimal` | Yes | Opening clock price. |
  | `:floor_price` | `Decimal` | Yes | Lowest price the clock will reach. Must be ≤ `:start_price`. |
  | `:decrement` | `Decimal` | Yes | Amount subtracted from the clock on each `tick/2` call. |

  `validate_config/1` enforces that all three keys are `Decimal` structs and
  that `floor_price <= start_price`.

  ## Lifecycle

  1. Build and open the auction with `Gavel.Auction.new/1` and `Gavel.Auction.open/2`.
  2. Call `start_clock/1` to initialise the clock in `auction.extra`.
  3. Drive the clock with repeated `tick/2` calls (e.g. on a timer).
  4. A participant calls `place_bid/3` at any point to accept the current price.
     The auction closes immediately on acceptance.
  5. If the auction is still open after the clock reaches the floor, call
     `resolve/2` to record `:no_sale`.

  ## Events emitted

  | Event | When |
  |-------|------|
  | `{:price_dropped, %{price: price}}` | Each `tick/2` |
  | `{:closed, %{result: result}}` | On `place_bid/3` acceptance or `resolve/2` |

  ## Example

  ```elixir
  now = DateTime.utc_now()

  {:ok, auction} =
    Gavel.Auction.new(%{
      type: Gavel.Types.Dutch,
      start_price: Decimal.new("500"),
      floor_price: Decimal.new("100"),
      decrement: Decimal.new("50")
    })

  auction =
    auction
    |> Gavel.Auction.open(now)
    |> Gavel.Types.Dutch.start_clock()

  # Tick once — price drops to 450.
  {:ok, auction, [{:price_dropped, %{price: _}}]} =
    Gavel.Types.Dutch.tick(auction, now)

  # A bidder accepts the current price.
  bid = Gavel.Bid.new(bidder: :alice, amount: Decimal.new("450"), placed_at: now)
  {:ok, auction, [{:closed, %{result: {:sold, :alice, price}}}]} =
    Gavel.Types.Dutch.place_bid(auction, bid, now)
  ```
  """
  @behaviour Gavel.Type
  @behaviour Gavel.Type.Clock

  alias Gavel.{Auction, Bid}
  alias Gavel.Types.Helpers

  @impl Gavel.Type
  @doc """
  Returns `:clock`, indicating this auction is driven by a descending price
  timer rather than competitive open bidding.
  """
  def kind, do: :clock

  @impl Gavel.Type
  @doc """
  Validates that `:start_price`, `:floor_price`, and `:decrement` are all
  `Decimal` structs, and that `floor_price` does not exceed `start_price`.

  Returns `:ok` on success, or one of:

  - `{:error, :unsupported_option}` — `:reserve_price` was supplied. Dutch
    auctions have no reserve; the seller's floor is `:floor_price` (the clock
    never descends below it). This is rejected rather than silently ignored.
  - `{:error, :missing_clock_config}` — one or more required keys are absent
    or are not `Decimal` values.
  - `{:error, :floor_above_start}` — `floor_price > start_price`.
  """
  def validate_config(config) do
    required = [:start_price, :floor_price, :decrement]

    cond do
      Map.has_key?(config, :reserve_price) ->
        {:error, :unsupported_option}

      Enum.any?(required, fn key -> not match?(%Decimal{}, Map.get(config, key)) end) ->
        {:error, :missing_clock_config}

      Decimal.compare(config.floor_price, config.start_price) == :gt ->
        {:error, :floor_above_start}

      true ->
        :ok
    end
  end

  @doc """
  Initialises the descending clock to `:start_price`.

  Stores the current price in `auction.extra.price`. Must be called once after
  `Gavel.Auction.open/2` and before the first `tick/2`.

  ## Parameters

  - `auction` — an open `Gavel.Auction.t()` whose config has already been
    validated by `validate_config/1`.

  Returns the updated auction struct with `extra.price` set.
  """
  @impl Gavel.Type.Clock
  @spec start_clock(Gavel.Auction.t()) :: Gavel.Auction.t()
  def start_clock(%Auction{config: config} = auction) do
    %{auction | extra: Map.put(auction.extra, :price, config.start_price)}
  end

  @impl Gavel.Type.Clock
  @doc """
  Advances the clock by subtracting `:decrement` from the current price.

  The price is clamped to `:floor_price` — it will never go below it.
  Emits `{:price_dropped, %{price: new_price}}`.

  Returns `{:ok, updated_auction, events}`.
  """
  def tick(%Auction{} = auction, _now) do
    floor = auction.config.floor_price
    next = Decimal.sub(current_price(auction), auction.config.decrement)
    next = if Decimal.compare(next, floor) == :lt, do: floor, else: next
    auction = %{auction | extra: Map.put(auction.extra, :price, next)}
    {:ok, auction, [{:price_dropped, %{price: next}}]}
  end

  @impl Gavel.Type
  @doc """
  Accepts the current clock price on behalf of `bid.bidder`, closing the
  auction immediately.

  The bid amount is ignored — the sale price is always the current clock
  price stored in `auction.extra.price`. This reflects the Dutch auction
  rule: the bidder accepts whatever the clock currently shows.

  Returns `{:ok, closed_auction, [{:closed, %{result: {:sold, bidder, price}}}]}`,
  or `{:error, :auction_closed}` if the auction is no longer open.
  """
  def place_bid(%Auction{} = auction, %Bid{} = bid, _now) do
    with :ok <- Helpers.ensure_open(auction) do
      price = current_price(auction)
      result = {:sold, bid.bidder, price}
      {:ok, %{auction | status: :closed, result: result}, [{:closed, %{result: result}}]}
    end
  end

  @impl Gavel.Type
  @doc """
  Closes an auction that reached the floor price with no takers.

  If the auction already has a result (i.e. `place_bid/3` was called first),
  this is a no-op — the auction is returned unchanged with an empty event
  list. Otherwise records `:no_sale` and closes the auction.

  Returns `{:ok, closed_auction, events}`.
  """
  def resolve(%Auction{result: nil} = auction, _now) do
    {:ok, %{auction | status: :closed, result: :no_sale}, [{:closed, %{result: :no_sale}}]}
  end

  def resolve(%Auction{} = auction, _now), do: {:ok, auction, []}

  defp current_price(%Auction{extra: %{price: p}}), do: p
  defp current_price(%Auction{config: %{start_price: p}}), do: p
end
