# Candle Auction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a seventh auction format, `Gavel.Types.Candle` — an open ascending auction (English bidding) that announces a public "final call" at `notice_at` and then closes at a hidden random time `notice_at + delay`.

**Architecture:** Candle reuses `Gavel.Types.English` unchanged for all bidding and reuses `Gavel.Types.Helpers` for winner/reserve resolution. The only new mechanism is a two-stage random ending: a public `:final_call` event at `notice_at`, and a hidden close stored in `auction.extra.secret_close`. Randomness is *injected* into the pure core via a new optional `Gavel.Type.on_notice/3` callback (the runtime supplies `:rand`; tests supply a fixed integer), exactly mirroring how `now` is injected everywhere else. `Gavel.Server` gains a `:notice` timer and reads its close deadline from `extra.secret_close` when present.

**Tech Stack:** Elixir, `Decimal`, ExUnit + `stream_data` (property tests), `Phoenix.PubSub` (optional runtime broadcasts).

---

## File structure

- **Modify** `lib/gavel/type.ex` — declare the optional `on_notice/3` callback.
- **Create** `lib/gavel/types/candle.ex` — the new format module (`kind/0`, `validate_config/1`, `place_bid/3`, `on_notice/3`, `resolve/2`).
- **Modify** `lib/gavel/server.ex` — arm a `:notice` timer; draw the random delay; read the close deadline from `extra.secret_close`.
- **Create** `test/gavel/types/candle_test.exs` — pure-core unit + property tests.
- **Modify** `test/gavel_test.exs` — runtime (timer/recovery) tests.
- **Modify** `docs/design.md` — add a Candle row to the format table.

No persistence code is needed: `secret_close` is a `DateTime` in `extra`, and `Auction.dump/1`/`load/1` already round-trip `extra` DateTimes as `{:dt, …}`.

---

## Task 1: Declare the `on_notice/3` callback on `Gavel.Type`

**Files:**
- Modify: `lib/gavel/type.ex:91-95`

This is a behaviour declaration (no standalone unit test — it is exercised by Candle in later tasks). Verify via compilation.

- [ ] **Step 1: Add the callback and extend `@optional_callbacks`**

In `lib/gavel/type.ex`, replace the existing `drop_out/3` doc + callback + optional-callbacks block (currently lines 91-95):

```elixir
  @doc "Withdraw a bidder. Only Japanese implements this."
  @callback drop_out(Auction.t(), bidder :: term(), now :: DateTime.t()) ::
              {:ok, Auction.t(), events()} | {:error, term()}

  @doc """
  Fire the "final call" and fix the auction's hidden close time.

  Called once by the runtime when the public `:notice_at` is reached. The
  random burn-down delay is *injected* as `delay_seconds` (the runtime supplies
  `:rand`; tests pass a fixed integer), keeping the core deterministic — exactly
  like the injected `now` argument elsewhere. The callback records the hidden
  close in `auction.extra.secret_close` and emits a `:final_call` event. Only
  `Gavel.Types.Candle` implements this.
  """
  @callback on_notice(Auction.t(), delay_seconds :: non_neg_integer(), now :: DateTime.t()) ::
              {:ok, Auction.t(), events()}

  @optional_callbacks drop_out: 3, on_notice: 3
```

- [ ] **Step 2: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: compiles with no warnings/errors.

- [ ] **Step 3: Commit**

```bash
git add lib/gavel/type.ex
git commit -m "feat(type): add optional on_notice/3 callback for candle auctions"
```

---

## Task 2: Create `Gavel.Types.Candle` with `kind/0` and `validate_config/1`

**Files:**
- Create: `lib/gavel/types/candle.ex`
- Test: `test/gavel/types/candle_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/gavel/types/candle_test.exs`:

```elixir
defmodule Gavel.Types.CandleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Gavel.{Auction, Bid}
  alias Gavel.Generators
  alias Gavel.Types.{Candle, Helpers}

  @now ~U[2026-06-01 12:00:00Z]
  @notice ~U[2026-06-01 12:10:00Z]

  defp valid_config(extra \\ %{}) do
    Map.merge(%{id: "c1", type: Candle, notice_at: @notice, max_delay: 30}, extra)
  end

  defp open_auction(config \\ %{}) do
    {:ok, a} = Auction.new(valid_config(config))
    Auction.open(a, @now)
  end

  describe "kind/0" do
    test "is :open" do
      assert Candle.kind() == :open
    end
  end

  describe "validate_config/1" do
    test "accepts a config with notice_at and max_delay" do
      assert :ok = Candle.validate_config(valid_config())
    end

    test "accepts an optional min_delay" do
      assert :ok = Candle.validate_config(valid_config(%{min_delay: 5}))
    end

    test "rejects a missing notice_at" do
      assert {:error, :missing_notice_at} =
               Candle.validate_config(%{type: Candle, max_delay: 30})
    end

    test "rejects a non-DateTime notice_at" do
      assert {:error, :missing_notice_at} =
               Candle.validate_config(%{type: Candle, notice_at: "soon", max_delay: 30})
    end

    test "rejects a missing max_delay" do
      assert {:error, :missing_max_delay} =
               Candle.validate_config(%{type: Candle, notice_at: @notice})
    end

    test "rejects a negative max_delay" do
      assert {:error, :negative_delay} = Candle.validate_config(valid_config(%{max_delay: -1}))
    end

    test "rejects a negative min_delay" do
      assert {:error, :negative_delay} = Candle.validate_config(valid_config(%{min_delay: -1}))
    end

    test "rejects min_delay greater than max_delay" do
      assert {:error, :min_delay_above_max} =
               Candle.validate_config(valid_config(%{min_delay: 40, max_delay: 30}))
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/gavel/types/candle_test.exs`
Expected: FAIL — `Gavel.Types.Candle` is undefined / module not available.

- [ ] **Step 3: Create the module with `kind/0` and `validate_config/1`**

Create `lib/gavel/types/candle.ex`:

```elixir
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
  `:missing_max_delay`, `:negative_delay`, `:min_delay_above_max`.
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
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/gavel/types/candle_test.exs`
Expected: PASS (all `kind/0` and `validate_config/1` tests).

- [ ] **Step 5: Commit**

```bash
git add lib/gavel/types/candle.ex test/gavel/types/candle_test.exs
git commit -m "feat(candle): add Candle type with kind/0 and validate_config/1"
```

---

## Task 3: `place_bid/3` — delegate to English, guard the hidden close

**Files:**
- Modify: `lib/gavel/types/candle.ex`
- Test: `test/gavel/types/candle_test.exs`

- [ ] **Step 1: Write the failing tests**

Append this `describe` block inside `test/gavel/types/candle_test.exs`, before the final `end`:

```elixir
  describe "place_bid/3" do
    defp bid(auction, bidder, amount, secs \\ 0) do
      b = Bid.new(bidder: bidder, amount: amount, placed_at: DateTime.add(@now, secs, :second))
      auction.type.place_bid(auction, b, b.placed_at)
    end

    test "delegates to English: first bid accepted, then a higher bid outbids" do
      {:ok, a, _} = bid(open_auction(), 1, "10")
      {:ok, a, events} = bid(a, 2, "12", 1)
      assert [{:bid_placed, _}, {:outbid, %{bidder: 1}}] = events
      assert Decimal.equal?(Helpers.highest(a.bids).amount, Decimal.new(12))
    end

    test "delegates to English: min_increment is enforced" do
      a = open_auction(%{min_increment: Decimal.new(5)})
      {:ok, a, _} = bid(a, 1, "10")
      assert {:error, :below_min_increment} = bid(a, 2, "12", 1)
    end

    test "accepts bids before the hidden close" do
      a = %{open_auction() | extra: %{secret_close: DateTime.add(@now, 100, :second)}}
      assert {:ok, _a, [{:bid_placed, _} | _]} = bid(a, 1, "10", 10)
    end

    test "rejects bids at or after the hidden close" do
      a = %{open_auction() | extra: %{secret_close: DateTime.add(@now, 100, :second)}}
      assert {:error, :auction_closed} = bid(a, 1, "10", 100)
      assert {:error, :auction_closed} = bid(a, 1, "10", 101)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/gavel/types/candle_test.exs`
Expected: FAIL — `place_bid/3` is undefined (or `UndefinedFunctionError`).

- [ ] **Step 3: Implement `place_bid/3`**

In `lib/gavel/types/candle.ex`, add after `validate_config/1`:

```elixir
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

  defp secret_close(%Auction{extra: extra}), do: Map.get(extra, :secret_close)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/gavel/types/candle_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/gavel/types/candle.ex test/gavel/types/candle_test.exs
git commit -m "feat(candle): place_bid delegates to English and guards the hidden close"
```

---

## Task 4: `on_notice/3` — set the hidden close, emit `:final_call`

**Files:**
- Modify: `lib/gavel/types/candle.ex`
- Test: `test/gavel/types/candle_test.exs`

- [ ] **Step 1: Write the failing tests**

Append this `describe` block inside `test/gavel/types/candle_test.exs`, before the final `end`:

```elixir
  describe "on_notice/3" do
    test "sets secret_close to notice_at + delay and emits final_call" do
      a = open_auction(%{max_delay: 30})
      {:ok, a, events} = Candle.on_notice(a, 12, @now)
      assert a.extra.secret_close == DateTime.add(@notice, 12, :second)
      assert [{:final_call, %{notice_at: @notice, max_delay: 30}}] = events
    end

    test "a zero delay closes the window exactly at notice_at" do
      a = open_auction()
      {:ok, a, _} = Candle.on_notice(a, 0, @now)
      assert a.extra.secret_close == @notice
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/gavel/types/candle_test.exs`
Expected: FAIL — `on_notice/3` is undefined.

- [ ] **Step 3: Implement `on_notice/3`**

In `lib/gavel/types/candle.ex`, add after `place_bid/3`:

```elixir
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/gavel/types/candle_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/gavel/types/candle.ex test/gavel/types/candle_test.exs
git commit -m "feat(candle): on_notice sets the hidden close and emits final_call"
```

---

## Task 5: `resolve/2` — highest standing bid wins, reveal `closed_at`

**Files:**
- Modify: `lib/gavel/types/candle.ex`
- Test: `test/gavel/types/candle_test.exs`

- [ ] **Step 1: Write the failing tests**

Append this `describe` block inside `test/gavel/types/candle_test.exs`, before the final `end`:

```elixir
  describe "resolve/2" do
    test "sells to the highest bidder at their own bid and reveals closed_at" do
      a = open_auction()
      {:ok, a, _} = Candle.on_notice(a, 10, @now)
      {:ok, a, _} = bid(a, 1, "10", 1)
      {:ok, a, _} = bid(a, 2, "20", 2)
      {:ok, a, events} = Candle.resolve(a, @now)

      assert a.status == :closed
      assert {:sold, 2, price} = a.result
      assert Decimal.equal?(price, Decimal.new(20))
      assert [{:closed, %{result: {:sold, 2, _}, closed_at: closed_at}}] = events
      assert closed_at == DateTime.add(@notice, 10, :second)
    end

    test "with no bids the result is :no_sale" do
      {:ok, a, [{:closed, %{result: :no_sale}}]} = Candle.resolve(open_auction(), @now)
      assert a.result == :no_sale
    end

    test "a top bid below the reserve yields :no_sale" do
      a = open_auction(%{reserve_price: Decimal.new(50)})
      {:ok, a, _} = bid(a, 1, "20")
      {:ok, a, _} = Candle.resolve(a, @now)
      assert a.result == :no_sale
    end

    property "the winner is always the highest accepted bid; ties go to the earliest" do
      check all(pairs <- Generators.bid_pairs()) do
        a = open_auction()

        a =
          pairs
          |> Enum.with_index()
          |> Enum.reduce(a, fn {{bidder, amount}, i}, acc ->
            b = Bid.new(bidder: bidder, amount: amount, placed_at: DateTime.add(@now, i, :second))
            Auction.put_bid(acc, b)
          end)

        {:ok, a, _} = Candle.resolve(a, @now)
        top = a.bids |> Helpers.ranked_desc() |> hd()
        assert {:sold, winner, price} = a.result
        assert winner == top.bidder
        assert Decimal.equal?(price, top.amount)
      end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/gavel/types/candle_test.exs`
Expected: FAIL — `resolve/2` is undefined.

- [ ] **Step 3: Implement `resolve/2`**

In `lib/gavel/types/candle.ex`, add after `on_notice/3`:

```elixir
  @impl true
  @doc """
  Closes the auction: the highest standing bid wins if it clears the reserve.

  Every bid in `auction.bids` was accepted before the hidden close (enforced by
  `place_bid/3`), so resolution is simply the highest bid meeting the reserve —
  the same rule English uses. Reveals the actual close time as `:closed_at` in
  the event. Returns `:no_sale` when there are no bids or the top bid is below
  the reserve.
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

    closed_at = Map.get(auction.extra, :secret_close)

    {:ok, %{auction | status: :closed, result: result},
     [{:closed, %{result: result, closed_at: closed_at}}]}
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/gavel/types/candle_test.exs`
Expected: PASS (including the property test).

- [ ] **Step 5: Run the full pure suite to confirm no regressions**

Run: `mix test test/gavel/types/`
Expected: PASS — English and the other type tests are unchanged and green.

- [ ] **Step 6: Commit**

```bash
git add lib/gavel/types/candle.ex test/gavel/types/candle_test.exs
git commit -m "feat(candle): resolve to the highest standing bid, reveal closed_at"
```

---

## Task 6: Runtime — `:notice` timer, random delay draw, hidden-close scheduling

**Files:**
- Modify: `lib/gavel/server.ex` — `arm_timers/1` (line 309-313), `schedule_close/1` (line 328-334), and add `handle_info(:notice, …)`, `schedule_notice/1`, `draw_delay/1`, `effective_close/1`.

Runtime timing is covered by integration tests in Task 7. This task wires the server; verify with `mix compile` here, then prove behavior in Task 7.

- [ ] **Step 1: Add a `:notice` handler**

In `lib/gavel/server.ex`, add these two clauses immediately after the existing `handle_info(:tick, state)` fallback (after line 245) and before the `:close` handlers:

```elixir
  def handle_info(:notice, %{auction: %{status: :open} = auction} = state) do
    delay = draw_delay(auction.config)
    {:ok, auction, events} = auction.type.on_notice(auction, delay, now())
    state = commit(state, auction, events)
    {:noreply, schedule_close(state)}
  end

  def handle_info(:notice, state), do: {:noreply, state}
```

- [ ] **Step 2: Arm the notice timer alongside the others**

Replace `arm_timers/1` (lines 309-313):

```elixir
  defp arm_timers(state) do
    state
    |> schedule_tick()
    |> schedule_notice()
    |> schedule_close()
  end
```

- [ ] **Step 3: Add `schedule_notice/1`**

Add immediately after `schedule_tick(state), do: state` (after line 326):

```elixir
  # Candle: arm a one-shot timer to fire the public final-call at notice_at.
  # Skipped once secret_close is set (already noticed), so it never re-fires
  # after a crash/rehydrate.
  defp schedule_notice(%{auction: %Auction{config: config, extra: extra, status: :open}} = state) do
    case {Map.get(config, :notice_at), Map.get(extra, :secret_close)} do
      {%DateTime{} = notice_at, nil} ->
        ms = max(DateTime.diff(notice_at, now(), :millisecond), 0)
        ref = Process.send_after(self(), :notice, ms)
        put_in(state, [:timers, :notice], ref)

      _ ->
        state
    end
  end

  defp schedule_notice(state), do: state
```

- [ ] **Step 4: Make `schedule_close/1` prefer the hidden close**

Replace `schedule_close/1` (lines 328-334):

```elixir
  defp schedule_close(%{auction: %Auction{} = auction} = state) do
    case effective_close(auction) do
      %DateTime{} = closes_at ->
        ms = max(DateTime.diff(closes_at, now(), :millisecond), 0)
        ref = Process.send_after(self(), :close, ms)
        put_in(state, [:timers, :close], ref)

      _ ->
        state
    end
  end

  # A candle's real close lives hidden in extra.secret_close (set at notice).
  # Every other format uses the public closes_at field.
  defp effective_close(%Auction{extra: extra, closes_at: closes_at}) do
    Map.get(extra, :secret_close) || closes_at
  end
```

- [ ] **Step 5: Add `draw_delay/1`**

Add immediately after `effective_close/1`:

```elixir
  # Uniform integer in [min_delay, max_delay]. :rand.uniform(n) returns 1..n,
  # so this yields min..max inclusive and collapses to min when min == max.
  defp draw_delay(config) do
    min = Map.get(config, :min_delay, 0)
    max = Map.fetch!(config, :max_delay)
    min + :rand.uniform(max - min + 1) - 1
  end
```

- [ ] **Step 6: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: compiles with no warnings/errors.

- [ ] **Step 7: Confirm existing runtime tests still pass**

Run: `mix test test/gavel_test.exs`
Expected: PASS — no behavior change for English/Dutch (no `notice_at`, no `secret_close`).

- [ ] **Step 8: Commit**

```bash
git add lib/gavel/server.ex
git commit -m "feat(server): drive candle notice timer and hidden-close scheduling"
```

---

## Task 7: Runtime integration tests (auto-close, burn-down, crash recovery)

**Files:**
- Modify: `test/gavel_test.exs`

- [ ] **Step 1: Add a polling helper and the integration tests**

In `test/gavel_test.exs`, add this private helper and the three tests inside the `GavelTest` module, before the final `end`:

```elixir
  # Poll a condition for up to retries*10 ms. Runtime timers fire in real time,
  # so we wait rather than assert synchronously.
  defp eventually(fun, retries \\ 200) do
    cond do
      fun.() -> :ok
      retries == 0 -> flunk("condition was never met")
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
    eventually(fn -> Gavel.get("candle3").status == :closed end)
    assert {:sold, 1, _} = Gavel.get("candle3").result
  end
```

- [ ] **Step 2: Run the runtime tests**

Run: `mix test test/gavel_test.exs`
Expected: PASS — all existing tests plus the three new candle tests.

- [ ] **Step 3: Commit**

```bash
git add test/gavel_test.exs
git commit -m "test(candle): runtime auto-close, burn-down, and crash recovery"
```

---

## Task 8: Documentation and full verification

**Files:**
- Modify: `docs/design.md:68-76` (format table)

- [ ] **Step 1: Add a Candle row to the format table**

In `docs/design.md`, the format table currently ends with the Japanese row (line 75). Add this row immediately after it:

```markdown
| **Candle** | yes | highest | own bid | English bidding + public final-call, then a hidden random close |
```

- [ ] **Step 2: Note the random ending below the table**

In `docs/design.md`, immediately after the `SealedFirstPrice` paragraph that follows the table (after line 79), add:

```markdown
**Candle:** an English auction with a two-stage random ending. A public `notice_at`
broadcasts a `:final_call`; the lot then closes at a hidden `notice_at + delay`
(`delay` uniform in `[min_delay, max_delay]`). All bids during the burn-down count;
the format is snipe-proof yet transparent. Randomness is injected into the pure
core via the optional `on_notice/3` callback, keeping resolution deterministic.
```

- [ ] **Step 3: Run the full test suite**

Run: `mix test`
Expected: PASS — entire suite green.

- [ ] **Step 4: Run formatter, linter, and type checker**

Run: `mix format && mix credo && mix dialyzer`
Expected: formatter makes no changes (or only the new files; re-stage if so); `credo` reports no issues on the new/changed files; `dialyzer` reports no new errors.

- [ ] **Step 5: Commit**

```bash
git add docs/design.md
git commit -m "docs(candle): document the candle format in the design doc"
```

---

## Self-review notes (verified against the spec)

- **Spec coverage:** `on_notice/3` callback (Task 1); `kind`/`validate_config` (Task 2); `place_bid` delegation + close guard (Task 3); `on_notice` impl (Task 4); `resolve` + `closed_at` (Task 5); server notice timer + `effective_close` + `draw_delay` (Task 6); runtime final-call/auto-close/recovery (Task 7); docs (Task 8). Persistence needs no code (covered by existing `dump`/`load` of `extra` DateTimes) — exercised by the Task 7 recovery test.
- **Type consistency:** `extra.secret_close` (a `DateTime`) and the `:final_call`/`:closed` event payload keys (`notice_at`, `max_delay`, `result`, `closed_at`) are used identically across the type module, the server, and the tests. `draw_delay/1` returns an integer in `[min_delay, max_delay]`, matching `on_notice/3`'s `non_neg_integer()` contract.
- **No placeholders:** every code and command step is concrete.
