defmodule Gavel.Types.Candle do
  @moduledoc """
  Open ascending "candle" auction with a two-stage random ending.

  Bidding is identical to `Gavel.Types.English` (public bids, minimum
  increments, proxy/max bids, optional reserve) — Candle delegates straight to
  it. The only difference is how the auction ends:

    1. The auction runs openly until the public, announced `:notice_at` (`t`).
    2. At `t`, all participants are notified at once with a `{:final_call, …}`
       event. The auction stays open.
    3. The auction then closes at `t + delay`, where `delay` is a *hidden*
       random number of seconds in `[min_delay, max_delay]`. The leading bid at
       the close wins.

  Every bid placed during the burn-down window `[t, t + delay]` counts — nothing
  is ever voided. The format is snipe-proof (you cannot snipe a close you cannot
  see) yet transparent (everyone receives the same warning, and the only hidden
  quantity is exactly when — within an announced bound — the candle goes out).

  ## Config keys

  | Key | Type | Required | Description |
  |-----|------|----------|-------------|
  | `:notice_at` | `DateTime` | **Yes** | When the `:final_call` warning fires (`t`). |
  | `:max_delay` | integer (seconds) | **Yes** | Upper bound of the burn-down delay after `t`. |
  | `:min_delay` | integer (seconds) | No (default `0`) | Guaranteed burn before the candle can go out. |
  | `:start_price` | `Decimal` | No | Floor for the first visible bid (English semantics). |
  | `:min_increment` | `Decimal` | No | Minimum raise over the current price (English semantics). |
  | `:reserve_price` | `Decimal` | No | Minimum acceptable winning price; below it the result is `:no_sale`. |

  `:anti_snipe` is not supported — the format is inherently snipe-proof.

  ## Events emitted

  | Event | When |
  |-------|------|
  | `{:bid_placed, %{bid: bid}}` | A bid is accepted (delegated to English) |
  | `{:outbid, %{bidder: bidder}}` | The leader changes (delegated to English) |
  | `{:final_call, %{notice_at: t, max_delay: m}}` | At `:notice_at` |
  | `{:closed, %{result: result, closed_at: close}}` | At the hidden close |

  ## Example

  ```elixir
  now = DateTime.utc_now()

  {:ok, auction} =
    Gavel.Auction.new(%{
      type: Gavel.Types.Candle,
      notice_at: DateTime.add(now, 600, :second),
      min_delay: 5,
      max_delay: 30,
      min_increment: Decimal.new("1")
    })

  auction = Gavel.Auction.open(auction, now)

  bid = Gavel.Bid.new(bidder: :alice, amount: Decimal.new("100"), placed_at: now)
  {:ok, auction, _events} = Gavel.Types.Candle.place_bid(auction, bid, now)

  # The runtime fires this at notice_at with an injected random delay:
  {:ok, auction, [{:final_call, _}]} = Gavel.Types.Candle.on_notice(auction, 12, now)

  {:ok, auction, [{:closed, %{result: result}}]} =
    Gavel.Types.Candle.resolve(auction, now)

  # => {:sold, :alice, Decimal.new("100")}
  ```
  """
  @behaviour Gavel.Type

  alias Gavel.{Auction, Bid}
  alias Gavel.Types.{English, Helpers}

  @impl true
  @doc "Returns `:open` — bids are public and there is no sealed phase."
  def kind, do: :open

  @impl true
  @doc """
  Validates the Candle config.

  Requires a `DateTime` `:notice_at` and an integer `:max_delay`. `:min_delay`
  is optional (default `0`). Both delays must be non-negative and
  `min_delay <= max_delay`. Returns `:ok` or one of `:missing_notice_at`,
  `:missing_max_delay`, `:negative_delay`, `:min_delay_above_max`. A
  non-integer `:min_delay` is also reported as `:negative_delay`.
  """
  def validate_config(config) do
    min = Map.get(config, :min_delay, 0)
    max = Map.get(config, :max_delay)

    cond do
      not match?(%DateTime{}, Map.get(config, :notice_at)) -> {:error, :missing_notice_at}
      not is_integer(max) -> {:error, :missing_max_delay}
      not is_integer(min) -> {:error, :negative_delay}
      min < 0 or max < 0 -> {:error, :negative_delay}
      min > max -> {:error, :min_delay_above_max}
      true -> :ok
    end
  end

  @impl true
  @doc """
  Places a public bid using English's rules.

  Before the `:final_call` fires there is no hidden close and bidding is exactly
  English. Once `extra.secret_close` is set, a bid whose `now` is at or after
  that hidden close is rejected with `{:error, :auction_closed}` — this closes
  the race between the runtime's close timer and a late bid. Otherwise the bid
  is delegated to `Gavel.Types.English.place_bid/3`.
  """
  def place_bid(%Auction{} = auction, %Bid{} = bid, %DateTime{} = now) do
    case secret_close(auction) do
      %DateTime{} = close ->
        if DateTime.compare(now, close) == :lt do
          English.place_bid(auction, bid, now)
        else
          {:error, :auction_closed}
        end

      nil ->
        English.place_bid(auction, bid, now)
    end
  end

  @impl true
  @doc """
  Fires the final call and fixes the hidden close at `notice_at + delay_seconds`.

  `delay_seconds` is the injected random burn-down delay (the runtime draws it
  with `:rand`; tests pass a fixed integer). Records the result in
  `extra.secret_close` and emits `{:final_call, %{notice_at: t, max_delay: m}}`.
  The `now` argument is unused — the close is anchored to the announced
  `notice_at`, not to when the timer happened to fire — but is accepted for
  callback-signature compatibility.
  """
  def on_notice(%Auction{config: config, extra: extra} = auction, delay_seconds, %DateTime{} = _now)
      when is_integer(delay_seconds) and delay_seconds >= 0 do
    notice_at = Map.fetch!(config, :notice_at)
    secret_close = DateTime.add(notice_at, delay_seconds, :second)

    auction = %{auction | extra: Map.put(extra, :secret_close, secret_close)}
    events = [{:final_call, %{notice_at: notice_at, max_delay: Map.fetch!(config, :max_delay)}}]

    {:ok, auction, events}
  end

  defp secret_close(%Auction{extra: extra}), do: Map.get(extra, :secret_close)
end
