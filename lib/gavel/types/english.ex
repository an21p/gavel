defmodule Gavel.Types.English do
  @moduledoc """
  Open ascending auction: the highest bidder at close wins and pays their own
  bid amount.

  This is the most common auction format. Bids are public and must rise by at
  least a configurable minimum increment. A proxy (automatic) bidding system
  is built in: when a bid includes a `max_amount`, the engine automatically
  advances the visible amount to stay one increment ahead of competitors up to
  that ceiling.

  ## Config keys

  | Key | Type | Required | Description |
  |-----|------|----------|-------------|
  | `:start_price` | `Decimal` | No | Floor for the first visible bid. Defaults to `0`. |
  | `:min_increment` | `Decimal` | No | Minimum raise over the current price. No increment rule when absent. |
  | `:reserve_price` | `Decimal` | No | Minimum acceptable winning price. No reserve when absent. |
  | `:closes_at` | `DateTime` | No | Hard deadline. Required for anti-snipe to function. |
  | `:anti_snipe` | `%{window: integer, extend_by: integer}` | No | Extend the deadline by `extend_by` seconds when a bid arrives within `window` seconds of `closes_at`. |

  ## Events emitted

  | Event | When |
  |-------|------|
  | `{:bid_placed, %{bid: bid}}` | A bid is accepted |
  | `{:outbid, %{bidder: bidder}}` | The previous leader is displaced |
  | `{:extended, %{closes_at: new_deadline}}` | Anti-snipe extension fires |
  | `{:closed, %{result: result}}` | Auction resolves |

  ## Example

  ```elixir
  now = DateTime.utc_now()

  {:ok, auction} =
    Gavel.Auction.new(%{
      type: Gavel.Types.English,
      start_price: Decimal.new("100"),
      min_increment: Decimal.new("10"),
      reserve_price: Decimal.new("150"),
      closes_at: DateTime.add(now, 3600, :second)
    })

  auction = Gavel.Auction.open(auction, now)

  bid_alice = Gavel.Bid.new(bidder: :alice, amount: Decimal.new("100"), placed_at: now)
  {:ok, auction, _events} = Gavel.Types.English.place_bid(auction, bid_alice, now)

  # Proxy bid: Bob's max is 250 but he only leads by one increment for now.
  bid_bob =
    Gavel.Bid.new(
      bidder: :bob,
      amount: Decimal.new("110"),
      max_amount: Decimal.new("250"),
      placed_at: now
    )

  {:ok, auction, _events} = Gavel.Types.English.place_bid(auction, bid_bob, now)

  {:ok, auction, [{:closed, %{result: result}}]} =
    Gavel.Types.English.resolve(auction, now)

  # => {:sold, :bob, <winning_amount>}
  ```
  """
  @behaviour Gavel.Type

  alias Gavel.{Auction, Bid}
  alias Gavel.Types.Helpers

  @impl true
  @doc """
  Returns `:open`, indicating bids are public and no sealed phase is used.
  """
  def kind, do: :open

  @impl true
  @doc """
  Validates the English auction config.

  All config keys are optional for an English auction, so this always returns
  `:ok`. Validation of individual key types (e.g. ensuring `:min_increment` is
  a `Decimal`) is left to the caller.
  """
  def validate_config(_config), do: :ok

  @impl true
  @doc """
  Places a public bid, enforcing increment rules and triggering anti-snipe.

  The bid is admissible when its ceiling (`:max_amount` for proxy bids, or
  `:amount` for plain bids) strictly exceeds the current visible price by at
  least `:min_increment`. On success the engine recomputes all visible amounts
  via the proxy algorithm so the leaderboard remains consistent.

  ## Events

  On success, always emits `{:bid_placed, %{bid: bid}}`. Additionally emits
  `{:outbid, %{bidder: previous_leader}}` when the leader changes, and
  `{:extended, %{closes_at: new_deadline}}` when the anti-snipe rule fires.

  ## Errors

  - `{:error, :auction_closed}` — the auction is not open.
  - `{:error, :bid_too_low}` — the ceiling does not exceed the current price.
  - `{:error, :below_min_increment}` — the ceiling exceeds the price but falls
    short of the minimum increment.
  """
  def place_bid(%Auction{} = auction, %Bid{} = bid, %DateTime{} = now) do
    with :ok <- Helpers.ensure_open(auction),
         :ok <- check_admissible(auction, bid) do
      prior = Helpers.highest(auction.bids)
      auction = auction |> Auction.put_bid(bid) |> recompute_visible_amounts()
      {auction, extend_events} = Helpers.maybe_extend(auction, now)

      events =
        [{:bid_placed, %{bid: bid}}] ++
          outbid_event(prior, Helpers.highest(auction.bids)) ++
          extend_events

      {:ok, auction, events}
    end
  end

  @impl true
  @doc """
  Closes the auction and determines the winner.

  The highest bidder wins if their visible amount meets or exceeds the reserve
  price. Returns `:no_sale` when there are no bids or the top bid is below the
  reserve.

  Always returns `{:ok, closed_auction, [{:closed, %{result: result}}]}` where
  `result` is `{:sold, bidder, amount}` or `:no_sale`.
  """
  def resolve(%Auction{} = auction, _now) do
    result =
      case Helpers.highest(auction.bids) do
        nil ->
          :no_sale

        %Bid{} = top ->
          if Helpers.clears_reserve?(top.amount, Helpers.reserve(auction)) do
            {:sold, top.bidder, top.amount}
          else
            :no_sale
          end
      end

    {:ok, %{auction | status: :closed, result: result}, [{:closed, %{result: result}}]}
  end

  # A bid is admissible if its *ceiling* (max_amount or amount) can beat the
  # current leader by the increment.
  defp check_admissible(auction, bid) do
    ceiling = bid.max_amount || bid.amount
    current = current_amount(auction)
    min = Map.get(auction.config, :min_increment)

    cond do
      current == nil -> :ok
      Decimal.compare(ceiling, current) != :gt -> {:error, :bid_too_low}
      Helpers.meets_increment?(ceiling, current, min) -> :ok
      true -> {:error, :below_min_increment}
    end
  end

  # Re-derive each bidder's visible amount from the set of ceilings, so the top
  # ceiling leads at one increment over the second ceiling (capped at its own max).
  # Plain (non-proxy) bids keep a visible amount >= their submitted amount.
  defp recompute_visible_amounts(auction) do
    min = Map.get(auction.config, :min_increment) || Decimal.new(0)
    start = Map.get(auction.config, :start_price) || Decimal.new(0)
    ranked = rank_by_ceiling(auction.bids)

    bids =
      case ranked do
        [] -> []
        [leader] -> [%{leader | amount: lone_leader_amount(leader, start)}]
        [leader, runner | rest] -> apply_contested(leader, runner, rest, min, start)
      end

    %{auction | bids: bids}
  end

  # Sort bids by ceiling desc; ties broken by earliest placed_at.
  defp rank_by_ceiling(bids) do
    Enum.sort(bids, fn a, b ->
      case Decimal.compare(ceiling(a), ceiling(b)) do
        :gt -> true
        :lt -> false
        :eq -> DateTime.compare(a.placed_at, b.placed_at) != :gt
      end
    end)
  end

  # Visible amount for a lone leader: proxy shows start_price, plain keeps amount.
  defp lone_leader_amount(%Bid{max_amount: nil, amount: a}, _start), do: a
  defp lone_leader_amount(_proxy_bid, start), do: start

  # Derive visible amounts when there are at least two bidders.
  defp apply_contested(leader, runner, rest, min, start) do
    runner_ceiling = ceiling(runner)
    target = dec_max(dec_min(ceiling(leader), Decimal.add(runner_ceiling, min)), start)
    leader_visible = contested_leader_amount(leader, target)
    runner_visible = dec_max(start, base_amount(runner))
    [%{leader | amount: leader_visible}, %{runner | amount: runner_visible} | rest]
  end

  # For a plain bid, never reduce below the submitted amount.
  # For a proxy bid, use the auto-advanced target directly.
  defp contested_leader_amount(%Bid{max_amount: nil} = leader, target),
    do: dec_max(target, base_amount(leader))

  defp contested_leader_amount(_proxy_bid, target), do: target

  defp ceiling(%Bid{max_amount: nil, amount: a}), do: a
  defp ceiling(%Bid{max_amount: m}), do: m
  defp base_amount(%Bid{amount: a}), do: a
  defp dec_min(a, b), do: if(Decimal.compare(a, b) == :lt, do: a, else: b)
  defp dec_max(a, b), do: if(Decimal.compare(a, b) == :gt, do: a, else: b)

  defp current_amount(auction) do
    case Helpers.highest(auction.bids) do
      nil -> nil
      %Bid{amount: amount} -> amount
    end
  end

  defp outbid_event(nil, _new), do: []
  defp outbid_event(%Bid{bidder: same}, %Bid{bidder: same}), do: []
  defp outbid_event(%Bid{bidder: prior}, _new), do: [{:outbid, %{bidder: prior}}]
end
