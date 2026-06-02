# Dutch Floor Auto No-Sale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a Dutch (descending-clock) auction close itself as `:no_sale` in the same tick that reaches the floor price, instead of dwelling at the floor for an extra interval and relying on the runtime to detect a stalled clock.

**Architecture:** The floor-end rule moves into the pure `Gavel.Types.Dutch` type (consistent with `Dutch.place_bid/3`, which already self-closes on acceptance). `Gavel.Server`'s tick handler reverts to its original three lines because `commit/3` cancels timers on close and `schedule_tick/1` no-ops on a closed auction. gavelui (`live_gavel`) needs no production change — the `{:closed, %{result: :no_sale}}` broadcast already propagates to the UI — only a propagation test is added.

**Tech Stack:** Elixir, ExUnit, Decimal, Phoenix.PubSub. Two sibling repos: `gavel` (core, at `~/apps/gavel`) and `live_gavel` (gavelui, at `~/apps/live_gavel`).

**Spec:** `~/apps/gavel/docs/superpowers/specs/2026-06-02-dutch-floor-auto-no-sale-design.md`

---

## File Structure

- `gavel/lib/gavel/types/dutch.ex` — `tick/2` gains the floor-close branch + closed-auction guard; moduledoc updated. **Core behaviour change.**
- `gavel/lib/gavel/server.ex` — revert uncommitted stall-detection block + helpers to the original tick handler.
- `gavel/test/gavel/types/dutch_test.exs` — update the floor test; add floor-close + closed-tick-noop tests.
- `gavel/test/gavel/server_test.exs` — keep the existing Dutch-floor integration test (no change; verify still green).
- `live_gavel/test/live_gavel/showcase_test.exs` — add end-to-end propagation test.

All `git` commits use the project identity:
`git -c user.email="antonis@pishias.com" -c user.name="Antonis" commit ...`
(plain `git commit` is fine if global identity already resolves to that email).

---

## Task 1: Dutch `tick/2` closes at the floor (pure type)

**Files:**
- Modify: `~/apps/gavel/lib/gavel/types/dutch.ex` (`tick/2` at lines 139-145; add a guard clause)
- Test: `~/apps/gavel/test/gavel/types/dutch_test.exs`

- [ ] **Step 1: Rewrite the "not below floor" test to expect a floor-close**

In `test/gavel/types/dutch_test.exs`, replace the existing test:

```elixir
test "tick lowers the price by decrement, not below floor" do
  a = dutch()
  {:ok, a, [{:price_dropped, _}]} = Dutch.tick(a, @now)
  assert Decimal.equal?(a.extra.price, Decimal.new(90))

  a =
    Enum.reduce(1..10, a, fn _, acc ->
      {:ok, acc, _} = Dutch.tick(acc, @now)
      acc
    end)

  assert Decimal.equal?(a.extra.price, Decimal.new(50))
end
```

with these two tests (config: start 100, floor 50, decrement 10 → above-floor
ticks at 90,80,70,60; the tick computing 50 reaches the floor and closes):

```elixir
test "tick lowers the price by decrement while above the floor" do
  a = dutch()
  {:ok, a, [{:price_dropped, %{price: p}}]} = Dutch.tick(a, @now)
  assert Decimal.equal?(a.extra.price, Decimal.new(90))
  assert Decimal.equal?(p, Decimal.new(90))
  assert a.status == :open
end

test "the tick that reaches the floor closes the auction as no_sale" do
  # 100 -> 90 -> 80 -> 70 -> 60, then the 5th tick would compute 50 (the floor)
  # and must close immediately with no :price_dropped event.
  a =
    Enum.reduce(1..4, dutch(), fn _, acc ->
      {:ok, acc, [{:price_dropped, _}]} = Dutch.tick(acc, @now)
      acc
    end)

  assert Decimal.equal?(a.extra.price, Decimal.new(60))

  {:ok, closed, events} = Dutch.tick(a, @now)
  assert events == [{:closed, %{result: :no_sale}}]
  assert closed.status == :closed
  assert closed.result == :no_sale
  assert Decimal.equal?(closed.extra.price, Decimal.new(50))
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/apps/gavel && mix test test/gavel/types/dutch_test.exs -v`
Expected: the new "reaches the floor closes" test FAILS — current `tick/2`
returns `{:price_dropped, ...}` and leaves `status: :open`, so the
`events == [{:closed, ...}]` assertion and the `status == :closed` assertion
fail.

- [ ] **Step 3: Implement the floor-close branch in `tick/2`**

In `lib/gavel/types/dutch.ex`, replace the current `tick/2` (lines 139-145):

```elixir
  def tick(%Auction{} = auction, _now) do
    floor = auction.config.floor_price
    next = Decimal.sub(current_price(auction), auction.config.decrement)
    next = if Decimal.compare(next, floor) == :lt, do: floor, else: next
    auction = %{auction | extra: Map.put(auction.extra, :price, next)}
    {:ok, auction, [{:price_dropped, %{price: next}}]}
  end
```

with a closed-auction guard plus the floor-close branch:

```elixir
  def tick(%Auction{status: :closed} = auction, _now), do: {:ok, auction, []}

  def tick(%Auction{} = auction, _now) do
    floor = auction.config.floor_price
    raw = Decimal.sub(current_price(auction), auction.config.decrement)

    if Decimal.compare(raw, floor) == :gt do
      auction = %{auction | extra: Map.put(auction.extra, :price, raw)}
      {:ok, auction, [{:price_dropped, %{price: raw}}]}
    else
      # Reached (or passed) the floor with no taker. The floor is a hard
      # no-sale: the clock never dwells there, so close in this same tick.
      auction = %{
        auction
        | extra: Map.put(auction.extra, :price, floor),
          status: :closed,
          result: :no_sale
      }

      {:ok, auction, [{:closed, %{result: :no_sale}}]}
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/apps/gavel && mix test test/gavel/types/dutch_test.exs -v`
Expected: PASS (all tests in the file).

- [ ] **Step 5: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/types/dutch.ex test/gavel/types/dutch_test.exs
git -c user.email="antonis@pishias.com" -c user.name="Antonis" \
  commit -m "feat(dutch): close as no_sale on the tick that reaches the floor"
```

---

## Task 2: `tick/2` on a closed auction is a no-op

**Files:**
- Test: `~/apps/gavel/test/gavel/types/dutch_test.exs` (guard clause already added in Task 1)

- [ ] **Step 1: Add the no-op test**

Append to `test/gavel/types/dutch_test.exs`:

```elixir
test "tick on an already-closed auction is a no-op" do
  # Drive it to the floor so it closes, then tick again.
  closed =
    Enum.reduce(1..5, dutch(), fn _, acc ->
      {:ok, acc, _} = Dutch.tick(acc, @now)
      acc
    end)

  assert closed.status == :closed
  assert closed.result == :no_sale

  assert {:ok, ^closed, []} = Dutch.tick(closed, @now)
end
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `cd ~/apps/gavel && mix test test/gavel/types/dutch_test.exs -v`
Expected: PASS. (The guard clause `tick(%Auction{status: :closed} ...)` added in
Task 1 already satisfies it; this test locks the behaviour in.)

- [ ] **Step 3: Commit**

```bash
cd ~/apps/gavel
git add test/gavel/types/dutch_test.exs
git -c user.email="antonis@pishias.com" -c user.name="Antonis" \
  commit -m "test(dutch): tick on a closed auction is a no-op"
```

---

## Task 3: Update the `Dutch` moduledoc

**Files:**
- Modify: `~/apps/gavel/lib/gavel/types/dutch.ex` (moduledoc lifecycle list ~lines 21-29; events table ~lines 32-36)

- [ ] **Step 1: Update the lifecycle step about reaching the floor**

In the `@moduledoc`, replace lifecycle step 5:

```
  5. If the auction is still open after the clock reaches the floor, call
     `resolve/2` to record `:no_sale`.
```

with:

```
  5. If the clock reaches the floor with no acceptance, `tick/2` closes the
     auction in that same tick and records `:no_sale` — the floor is a hard
     no-sale and is never an acceptable price. (`resolve/2` remains an
     idempotent safety net for the close timer / manual close.)
```

- [ ] **Step 2: Update the events table**

Replace the events table row for `:closed`:

```
  | `{:closed, %{result: result}}` | On `place_bid/3` acceptance or `resolve/2` |
```

with:

```
  | `{:closed, %{result: result}}` | On `place_bid/3` acceptance, the floor-reaching `tick/2`, or `resolve/2` |
```

- [ ] **Step 3: Update the second paragraph of the moduledoc**

Replace:

```
  Unlike ascending auctions there is no competitive bidding — the first
  acceptance closes the lot. If the clock reaches the floor price and no one
  has accepted, `resolve/2` records `:no_sale`.
```

with:

```
  Unlike ascending auctions there is no competitive bidding — the first
  acceptance closes the lot. If the clock reaches the floor price and no one
  has accepted, `tick/2` closes the lot immediately and records `:no_sale`.
```

- [ ] **Step 4: Verify it still compiles and tests pass**

Run: `cd ~/apps/gavel && mix test test/gavel/types/dutch_test.exs && mix format --check-formatted`
Expected: tests PASS; formatter reports no changes (or run `mix format` if it does).

- [ ] **Step 5: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/types/dutch.ex
git -c user.email="antonis@pishias.com" -c user.name="Antonis" \
  commit -m "docs(dutch): tick auto-closes at the floor as no_sale"
```

---

## Task 4: Revert the server stall-detection workaround

**Files:**
- Modify: `~/apps/gavel/lib/gavel/server.ex` (`handle_info(:tick, ...)` lines 238-257; helpers `clock_price/1` lines 284-285 and `clock_stalled?/2` lines 289-292)
- Test: `~/apps/gavel/test/gavel/server_test.exs` (existing Dutch-floor test — no change)

- [ ] **Step 1: Confirm the integration test exists and currently passes**

Run: `cd ~/apps/gavel && mix test test/gavel/server_test.exs -v`
Expected: PASS, including "a Dutch clock that reaches the floor with no taker
resolves to no_sale". (This test must STILL pass after the revert — it now
closes one interval sooner, well within its 300 ms sleep.)

- [ ] **Step 2: Revert the `:tick` handler to its original form**

In `lib/gavel/server.ex`, replace the current handler (lines 238-255):

```elixir
  @impl true
  def handle_info(:tick, %{auction: %{status: :open} = auction} = state) do
    before_price = clock_price(auction)
    {:ok, ticked, events} = auction.type.tick(auction, now())

    if clock_stalled?(before_price, clock_price(ticked)) do
      # The clock can no longer advance (e.g. a Dutch auction hit its floor with
      # no taker). The pure type leaves closing to the driver, so resolve here —
      # otherwise the :tick timer re-arms forever and the auction never ends.
      # The stalled tick's redundant price event is dropped in favour of the
      # close events.
      {:ok, resolved, close_events} = ticked.type.resolve(ticked, now())
      {:noreply, commit(state, resolved, close_events)}
    else
      state = commit(state, ticked, events)
      {:noreply, schedule_tick(state)}
    end
  end
```

with:

```elixir
  @impl true
  def handle_info(:tick, %{auction: %{status: :open} = auction} = state) do
    {:ok, auction, events} = auction.type.tick(auction, now())
    state = commit(state, auction, events)
    {:noreply, schedule_tick(state)}
  end
```

This is correct because `commit/3` cancels all timers when
`auction.status == :closed`, and `schedule_tick/1` only matches `status: :open`
(so it no-ops once the tick self-closed).

- [ ] **Step 3: Delete the now-unused helpers**

In `lib/gavel/server.ex`, delete the `clock_price/1` clauses and their comment:

```elixir
  # The clock price lives in `extra.price` for every `:clock` format (see the
  # `Gavel.Type.Clock` behaviour). `nil` for non-clock auctions, which never tick.
  defp clock_price(%Auction{extra: %{price: price}}), do: price
  defp clock_price(%Auction{}), do: nil

  # A tick that leaves the price unchanged means the clock has bottomed out
  # (Dutch floor) and can never close itself by movement — time to resolve.
  defp clock_stalled?(%Decimal{} = before, %Decimal{} = after_),
    do: Decimal.equal?(before, after_)

  defp clock_stalled?(_before, _after), do: false
```

- [ ] **Step 4: Run the server tests + compile to confirm no unused-function warnings**

Run: `cd ~/apps/gavel && mix test test/gavel/server_test.exs -v`
Expected: PASS (all 7 tests), no compiler warnings about unused private
functions.

- [ ] **Step 5: Run the full gavel suite + lint**

Run: `cd ~/apps/gavel && mix test && mix format --check-formatted && mix credo --strict`
Expected: all tests PASS; format clean; credo clean.

- [ ] **Step 6: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/server.ex
git -c user.email="antonis@pishias.com" -c user.name="Antonis" \
  commit -m "refactor(server): drop stall detection now that Dutch tick self-closes"
```

---

## Task 5: gavelui propagation test (live_gavel)

**Files:**
- Test: `~/apps/live_gavel/test/live_gavel/showcase_test.exs` (add one test; existing `setup` provides `id` and `on_exit` stop)

- [ ] **Step 1: Add the end-to-end propagation test**

Append to `test/live_gavel/showcase_test.exs` (inside the module). It starts a
Dutch auction via an explicit fast/narrow config so the floor is reached almost
immediately, subscribes to the auction topic, and asserts both the broadcast and
the resolved view model:

```elixir
test "a Dutch clock reaching the floor closes as no_sale and broadcasts it", %{id: id} do
  Phoenix.PubSub.subscribe(LiveGavel.PubSub, "auction:#{id}")

  # start 60, floor 50, decrement 10, 10ms ticks: 50 reached within ~20ms.
  {:ok, vm} =
    Showcase.start("dutch",
      id: id,
      config: %{
        start_price: Decimal.new("60"),
        floor_price: Decimal.new("50"),
        decrement: Decimal.new("10"),
        tick_interval_ms: 10
      }
    )

  assert vm.status == :open

  assert_receive {:gavel, ^id, {:closed, %{result: :no_sale}}}, 1_000

  closed = Showcase.get(id)
  assert closed.status == :closed
  assert closed.result == :no_sale
  assert Decimal.equal?(closed.current_price, Decimal.new("50"))
end
```

- [ ] **Step 2: Run the test**

Run: `cd ~/apps/live_gavel && mix test test/live_gavel/showcase_test.exs -v`
Expected: PASS. (The gavel server broadcasts on `"auction:<id>"` because
`config :gavel, pubsub: LiveGavel.PubSub` is set in `config/config.exs`.)

- [ ] **Step 3: Run the full live_gavel unit suite + lint**

Run: `cd ~/apps/live_gavel && mix test --exclude feature && mix format --check-formatted && mix credo --strict`
Expected: all tests PASS; format clean; credo clean. (If `mix credo` is not
configured here, skip it; do not add config.)

- [ ] **Step 4: Commit**

```bash
cd ~/apps/live_gavel
git add test/live_gavel/showcase_test.exs
git -c user.email="antonis@pishias.com" -c user.name="Antonis" \
  commit -m "test(showcase): Dutch floor closes as no_sale and propagates"
```

---

## Task 6: Final verification across both repos

**Files:** none (verification only)

- [ ] **Step 1: gavel full suite + lint**

Run: `cd ~/apps/gavel && mix test && mix format --check-formatted && mix credo --strict`
Expected: all PASS / clean.

- [ ] **Step 2: live_gavel full unit suite + lint**

Run: `cd ~/apps/live_gavel && mix test --exclude feature && mix format --check-formatted`
Expected: all PASS / clean.

- [ ] **Step 3: Confirm both working trees are committed**

Run: `cd ~/apps/gavel && git status --short && cd ~/apps/live_gavel && git status --short`
Expected: no Dutch-related changes left uncommitted. (Pre-existing unrelated
gavelui UI/CSS edits may remain — leave those untouched.)

---

## Self-Review Notes

- **Spec coverage:** Change #1 (Dutch `tick/2` close branch) → Task 1; closed-tick guard → Tasks 1+2; moduledoc → Task 3; change #2 (server revert) → Task 4; change #3 (gavelui propagation test) → Task 5. Edge cases (`start == floor`, decrement overshoot) are covered behaviourally by the `raw <= floor` branch and exercised by Task 1's overshoot (next computes 50 = floor) and Task 5's narrow range.
- **Type consistency:** `tick/2` returns `{:ok, auction, events}` throughout; close event is exactly `{:closed, %{result: :no_sale}}` everywhere (Tasks 1, 5). `extra.price` set to `floor` on close in both the unit assertion (Task 1) and the view-model assertion (Task 5, via `current_price`).
- **Scope:** Single subsystem (Dutch clock end-of-life). One plan.
