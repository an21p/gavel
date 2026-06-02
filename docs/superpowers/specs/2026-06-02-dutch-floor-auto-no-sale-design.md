# Dutch auction auto-ends as `:no_sale` on reaching the floor

**Date:** 2026-06-02
**Repos affected:** `gavel` (core), `live_gavel` (gavelui — test only)

## Problem

A Dutch (descending-clock) auction should end the moment the clock reaches the
floor price with no taker. Today the floor is *clamped* by `Dutch.tick/2` but
the auction stays open; closing relies on an out-of-band signal:

- The pure `Dutch.tick/2` clamps the price to `:floor_price` and keeps emitting
  `{:price_dropped, ...}` forever (the clock can no longer move).
- `Gavel.Server` works around this with stall detection (uncommitted WIP): it
  compares the price before/after a tick and, when they are equal, calls
  `resolve/2` to record `:no_sale`.

Consequences of the current behaviour:

1. The close happens **one tick interval *after*** the floor is reached. With the
   gavelui "slow clock" preset (2000 ms) the price sits displayed at the floor,
   still `:open`, for a full extra interval before closing.
2. The floor-end rule lives in the runtime (`Gavel.Server`), not in the Dutch
   type, even though it is a Dutch domain rule. The server has to reach into
   `auction.config` and infer "stalled" from price equality.

## Decision

**The floor is a hard no-sale.** The instant a tick brings the clock to (or
below) the floor with no acceptance, the auction closes as `:no_sale` in that
same tick. The floor price is therefore **never an offerable price** — the clock
never dwells there.

The floor-end rule moves **into the pure `Gavel.Types.Dutch` type**. This is
consistent with the existing design: `Dutch.place_bid/3` already self-closes the
auction on acceptance, so closing inside the type is an established pattern, not
a new one. It also makes `tick/2` correct for callers driving the clock manually
(per the module's documented lifecycle), and lets `Gavel.Server` shrink back to
its original tick handler.

### Approaches considered

- **A (chosen) — pure type self-closes.** `Dutch.tick/2` detects the
  floor-reaching tick and closes. `Gavel.Server`'s stall-detection workaround is
  reverted. Rule lives where the floor lives; server simplifies.
- **B — server closes one tick earlier.** Keep `tick/2` clamping; change the
  server's stall check to a "reached floor" check against `config.floor_price`.
  Rejected: splits the rule across two layers and forces the runtime to know
  Dutch-specific config.

## Changes

### 1. `gavel` — `Gavel.Types.Dutch.tick/2`

Compute `raw = current_price - decrement`.

- `raw > floor` — normal drop. Set `extra.price = raw`, emit
  `{:price_dropped, %{price: raw}}`. (Unchanged.)
- `raw <= floor` — floor reached with no taker. Set `extra.price = floor`,
  `status: :closed`, `result: :no_sale`, emit `{:closed, %{result: :no_sale}}`.
  No `:price_dropped` event is emitted for this tick — the floor is not an
  offerable price, so the event feed shows only "Closed — no sale" while the
  displayed price (read from `extra.price`) reads the floor.

Add a guard clause so a `tick/2` on an already-`:closed` auction is a no-op:
`{:ok, auction, []}`.

Update the moduledoc:

- Lifecycle step 5 changes from "call `resolve/2` to record `:no_sale`" to
  "`tick/2` auto-resolves to `:no_sale` when the clock reaches the floor".
- Events table: note that `tick/2` may emit `{:closed, %{result: :no_sale}}`.
- `resolve/2` is unchanged and remains the idempotent safety net used by the
  `:close` timer and `Gavel.Server.close/1` (returns `[]` when a result already
  exists).

### 2. `gavel` — `Gavel.Server.handle_info(:tick, …)`

Revert the uncommitted stall-detection block and its `clock_price/1` /
`clock_stalled?/2` helpers back to the original handler:

```elixir
def handle_info(:tick, %{auction: %{status: :open} = auction} = state) do
  {:ok, auction, events} = auction.type.tick(auction, now())
  state = commit(state, auction, events)
  {:noreply, schedule_tick(state)}
end
```

This is correct unchanged because:

- `commit/3` already cancels all timers when `auction.status == :closed`.
- `schedule_tick/1` already pattern-matches `status: :open` and no-ops on a
  closed auction, so the trailing call does nothing once the tick self-closed.

### 3. `live_gavel` (gavelui) — no production code change

The `{:closed, %{result: :no_sale}}` broadcast already propagates:
`Gavel.Server` broadcasts on `"auction:<id>"` → `Showcase` view model →
`AuctionLive` / `RoomLive` `handle_info({:gavel, id, {event, payload}})` →
`result_banner` renders "Closed — no sale"; `RoomLive` also unregisters the lot
from the marketplace when `status == :closed`. Only a test is added.

## Tests

- `gavel/test/gavel/types/dutch_test.exs`
  - Update "tick lowers the price by decrement, not below floor": the tick that
    reaches the floor now returns `{:closed, %{result: :no_sale}}`, with
    `status: :closed`, `result: :no_sale`, and `extra.price` at the floor.
  - Add: a `tick/2` on an already-closed auction is a no-op (`events == []`,
    state unchanged).
  - Keep: acceptance-before-floor still wins at the current price; `resolve/2`
    with no acceptance is still `:no_sale` (idempotent path).
- `gavel/test/gavel/server_test.exs`
  - Keep the existing "Dutch clock reaches the floor with no taker resolves to
    no_sale" integration test (it still passes and now closes one interval
    sooner).
- `live_gavel/test/live_gavel/showcase_test.exs`
  - New propagation test: start a Dutch showcase with a tiny `tick_interval_ms`
    and a short price range, poll until closed, assert
    `Showcase.get(id).status == :closed` and `result == :no_sale`, and that a
    `{:gavel, id, {:closed, %{result: :no_sale}}}` message is broadcast on the
    auction topic.

## Edge cases

- **`start_price == floor_price`** (allowed by `validate_config/1`, which only
  requires `floor <= start`): the first tick computes `raw < floor` and closes
  immediately as `:no_sale`. Acceptable — a zero-width clock has nothing to
  offer.
- **Decrement overshoots the floor** (e.g. 200 → would-be 50 with floor 100):
  `raw <= floor` triggers the close branch and `extra.price` is set to the
  floor, not the overshoot value.
- **Acceptance at the last above-floor price** still wins normally via
  `place_bid/3`; only the floor-reaching tick closes as no-sale.

## Out of scope

- No change to Japanese/other clock formats (no floor concept).
- No change to anti-snipe, `:close` timer, or `resolve/2` semantics.
- No gavelui UI/markup change beyond the added test.
