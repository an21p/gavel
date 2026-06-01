defmodule Gavel.Types.Helpers do
  @moduledoc """
  Pure helper functions shared across all auction format implementations.

  This module is an internal utility layer; it is not part of the public Gavel
  API but is documented here so that authors writing custom `Gavel.Type`
  implementations can reuse it safely.

  ## Helper categories

  | Helper | Purpose |
  |--------|---------|
  | `ranked_desc/1` | Sort bids highest-first (standard winner ranking) |
  | `ranked_asc/1` | Sort bids lowest-first (reverse/procurement auctions) |
  | `highest/1` | Peek at the current leading bid |
  | `meets_increment?/3` | Enforce a minimum raise size |
  | `reserve/1` | Extract the reserve price from auction config |
  | `clears_reserve?/2` | Guard a winning amount against the reserve |
  | `maybe_extend/2` | Apply anti-snipe deadline extension |
  | `ensure_open/1` | Reject any action on a non-open auction |

  Tie-breaking throughout uses *earliest `placed_at`* so that a bidder who bid
  first at the same amount is always preferred.
  """

  alias Gavel.Auction

  @doc """
  Sorts bids highest amount first, with ties broken by earliest `placed_at`.

  Used as the ranking function for standard (non-reverse) sealed and open
  auctions. The head of the returned list is the current winner.

  ## Parameters

  - `bids` — list of `Gavel.Bid.t()` structs to sort.

  Returns a new list; the original is not modified.
  """
  @spec ranked_desc([Gavel.Bid.t()]) :: [Gavel.Bid.t()]
  def ranked_desc(bids) do
    Enum.sort(bids, fn a, b ->
      case Decimal.compare(a.amount, b.amount) do
        :gt -> true
        :lt -> false
        :eq -> DateTime.compare(a.placed_at, b.placed_at) != :gt
      end
    end)
  end

  @doc """
  Sorts bids lowest amount first, with ties broken by earliest `placed_at`.

  Used as the ranking function for reverse/procurement auctions where the
  cheapest offer wins. The head of the returned list is the current winner.

  ## Parameters

  - `bids` — list of `Gavel.Bid.t()` structs to sort.

  Returns a new list; the original is not modified.
  """
  @spec ranked_asc([Gavel.Bid.t()]) :: [Gavel.Bid.t()]
  def ranked_asc(bids) do
    Enum.sort(bids, fn a, b ->
      case Decimal.compare(a.amount, b.amount) do
        :lt -> true
        :gt -> false
        :eq -> DateTime.compare(a.placed_at, b.placed_at) != :gt
      end
    end)
  end

  @doc """
  Returns the current highest bid, or `nil` when no bids have been placed.

  Delegates to `ranked_desc/1` and returns the head of the sorted list.

  ## Parameters

  - `bids` — list of `Gavel.Bid.t()` structs.
  """
  @spec highest([Gavel.Bid.t()]) :: Gavel.Bid.t() | nil
  def highest(bids), do: bids |> ranked_desc() |> List.first()

  @doc """
  Returns `true` when `amount` beats `floor` by at least `min_increment`.

  Handles all combinations of nil inputs:

  - If both `floor` and `min` are `nil`, any strictly positive `amount` is
    accepted (no existing bid, no increment rule).
  - If `floor` is `nil` but `min` is set, any strictly positive `amount` is
    accepted (no bid to beat yet).
  - If `floor` is set but `min` is `nil`, any amount strictly greater than
    `floor` is accepted.
  - If both are set, `amount` must be `>= floor + min`.

  ## Parameters

  - `amount` — the incoming bid amount as a `Decimal`.
  - `floor` — the current highest bid amount, or `nil` if no bids exist.
  - `min` — the configured minimum increment (`Decimal`), or `nil` if none.
  """
  @spec meets_increment?(Decimal.t(), Decimal.t() | nil, Decimal.t() | nil) :: boolean()
  def meets_increment?(amount, nil, nil), do: Decimal.compare(amount, Decimal.new(0)) == :gt
  def meets_increment?(amount, nil, _min), do: Decimal.compare(amount, Decimal.new(0)) == :gt

  def meets_increment?(amount, %Decimal{} = current, nil) do
    Decimal.compare(amount, current) == :gt
  end

  def meets_increment?(amount, %Decimal{} = current, %Decimal{} = min) do
    Decimal.compare(amount, Decimal.add(current, min)) != :lt
  end

  @doc """
  Extracts the `:reserve_price` from the auction's config map, or returns `nil`.

  A return value of `nil` means there is no reserve and every winning bid is
  unconditionally accepted.

  ## Parameters

  - `auction` — a `Gavel.Auction.t()` struct.
  """
  @spec reserve(Gavel.Auction.t()) :: Decimal.t() | nil
  def reserve(%Auction{config: config}), do: Map.get(config, :reserve_price)

  @doc """
  Returns `true` when `amount` meets or exceeds the reserve price.

  A `nil` reserve is treated as "no reserve" and always returns `true`.

  ## Parameters

  - `amount` — a `Decimal` winning amount to check.
  - `reserve` — a `Decimal` reserve price, or `nil`.
  """
  @spec clears_reserve?(Decimal.t(), Decimal.t() | nil) :: boolean()
  def clears_reserve?(_amount, nil), do: true

  def clears_reserve?(%Decimal{} = amount, %Decimal{} = reserve),
    do: Decimal.compare(amount, reserve) != :lt

  @doc """
  Applies anti-snipe logic: extends the auction deadline when a bid arrives
  inside the configured warning window.

  If the auction's `config` contains an `:anti_snipe` key of the form
  `%{window: seconds, extend_by: seconds}`, and the current time `now` is
  within `window` seconds of `closes_at`, the deadline is pushed out by
  `extend_by` seconds and an `{:extended, %{closes_at: new_deadline}}`
  event is appended.

  Returns `{auction, events}` where `events` is either `[]` (no extension
  needed) or a one-element list containing the `:extended` event. The
  function is a no-op when `closes_at` is `nil` (open-ended auctions).

  ## Parameters

  - `auction` — a `Gavel.Auction.t()` struct.
  - `now` — the current `DateTime`.
  """
  @spec maybe_extend(Gavel.Auction.t(), DateTime.t()) ::
          {Gavel.Auction.t(), [{atom(), map()}]}
  def maybe_extend(%Auction{config: config, closes_at: closes_at} = auction, %DateTime{} = now)
      when not is_nil(closes_at) do
    case Map.get(config, :anti_snipe) do
      %{window: window_s, extend_by: extend_s} ->
        remaining = DateTime.diff(closes_at, now, :second)

        if remaining >= 0 and remaining <= window_s do
          new_closes = DateTime.add(closes_at, extend_s, :second)
          {%{auction | closes_at: new_closes}, [{:extended, %{closes_at: new_closes}}]}
        else
          {auction, []}
        end

      _ ->
        {auction, []}
    end
  end

  def maybe_extend(auction, _now), do: {auction, []}

  @doc """
  Standard guard that rejects any action on a non-open auction.

  Returns `:ok` when the auction's `status` is `:open`, or
  `{:error, :auction_closed}` otherwise. Intended for use at the top of
  `place_bid/3`, `tick/2`, and `drop_out/3` implementations via `with`.

  ## Parameters

  - `auction` — a `Gavel.Auction.t()` struct.
  """
  @spec ensure_open(Gavel.Auction.t()) :: :ok | {:error, :auction_closed}
  def ensure_open(%Auction{status: :open}), do: :ok
  def ensure_open(%Auction{}), do: {:error, :auction_closed}
end
