# Multi-unit (multi-winner) auctions for Gavel

**Date:** 2026-06-02
**Status:** Design approved; spec written. No implementation plan yet.
**Depends on:** the `Gavel.Type.Clock` companion behaviour (`start_clock/1` + `tick/2`), already landed.

## Summary

Add a **multi-unit** auction family to Gavel: one seller offers `Q` identical/fungible
units, many buyers commit at different unit prices, and a single auction produces
**many winners at possibly many prices**. This is an explicit v1 non-goal in
`docs/design.md`, so it is a genuine expansion of the core, not a tweak to an existing
type.

Four formats ship, in two groups that share one data model:

- **Group A — sealed (one `resolve` pass):** `UniformPrice`, `PayAsBid`, `Vickrey`.
  They share the *exact same allocation pipeline* and differ **only in the payment rule**.
- **Group B — clock:** `Ausubel` (ascending clock, live per-tick demand reduction).
  Reproduces the VCG outcome dynamically. (Multi-unit Dutch was considered and dropped.)

## Goals

- One clean data model (`quantity` on bids, a dedicated allocation result) that serves
  all four formats and leaves the single-winner path untouched.
- Maximal reuse of the existing pure-core + OTP-runtime architecture: multi-unit sealed
  types are `kind: :sealed`; Ausubel is `kind: :clock` and uses the new
  `Gavel.Type.Clock` seam.
- Keep the core pure and deterministic (explicit `now`), so the allocation and clinching
  invariants are property-testable.

## Non-goals

- Combinatorial / package bids (bidders wanting specific bundles). Units are identical.
- Full per-bid demand *schedules* in a single submission. A bidder expresses a demand
  curve by submitting **multiple** `(unit_price, quantity)` lines that accumulate.
- Multi-unit Dutch and any double-auction (two-sided) format.
- Pro-rata allocation at the margin (strict time priority instead — see §6).

## Decisions locked during brainstorming

| Question | Decision |
|---|---|
| Unit type | Identical / fungible units (multi-unit), not combinatorial. |
| Bid shape | Price + quantity per bid line ("up to N units at unit price P"). |
| Demand curves | A bidder submits **several** lines; repeat `place_bid` calls **accumulate** (do NOT replace — diverges from `Gavel.Types.Sealed`). |
| Marginal fill | **Partial fill, divisible** — the marginal line takes the remaining units. |
| Marginal ties | Strict earliest-`placed_at` priority (no pro-rata). |
| Group A scope | `UniformPrice`, `PayAsBid`, `Vickrey`. |
| Group B scope | `Ausubel` ascending only; **live per-tick demand reduction**. |
| Integration | Approach 1: shared engine module + thin `Gavel.Type` modules; dedicated result struct rather than a widened `result` union. |

## 1. Data model

### `Gavel.Bid` gains `:quantity`

- New field `:quantity` (`Decimal.t() | nil`, default `nil`).
- `amount` is the **unit price**. Single-unit types ignore `quantity`; multi-unit types
  require it positive.
- `Decimal` (not integer) is chosen for consistency with money and to support divisible
  goods; integer units were rejected for that consistency.
- `Gavel.Auction.dump_bid/1` and `load_bid/1` carry the extra field (Decimal ↔ `{:dec, s}`).

### `Gavel.Allocation` — the multi-unit result

A dedicated struct, **not** added to the single-winner `{:sold, …}` union (that path
stays untouched, mirroring how the clock work isolated its contract in a companion
behaviour):

```elixir
%Gavel.Allocation{
  units_offered:  Decimal.t(),
  units_sold:     Decimal.t(),
  clearing_price: Decimal.t() | nil,   # set only for uniform-price; nil otherwise
  lines: [%{bidder: term(), quantity: Decimal.t(), amount: Decimal.t()}]
}
```

- `amount` is the **total** that bidder pays for their `quantity`
  (unit price = `amount / quantity`; may vary per bidder for `Vickrey`/`Ausubel`).
- This one shape serves all four formats.
- `Gavel.Auction.dump_result/1` and `load_result/1` extend to (de)serialize it
  (Decimals as `{:dec, s}`; the line maps round-trip as plain terms).

## 2. Shared sealed engine — `Gavel.Types.MultiUnit`

Mirrors `Gavel.Types.Sealed`: not a `Gavel.Type` itself, but the pipeline the three
sealed formats delegate to.

- **`place_bid/3`** — *accumulates* a `(bidder, unit_price, quantity)` line (no replace).
  Returns `{:error, :auction_closed}` if not open, `{:error, :invalid_quantity}` if
  `quantity` is missing or non-positive. Emits `{:bid_placed, %{bidder: bidder}}`
  (amount withheld, consistent with sealed mechanics).
- **`allocate/2`** — pure core. Given the bid lines and the reserve:
  1. Sort lines by unit price desc; ties broken by earliest `placed_at`.
  2. Walk down, allocating `min(line.quantity, remaining)` to each line.
  3. Lines with `unit_price < reserve` never win (skipped).
  4. Stop when `remaining == 0` or lines exhausted.
  5. The marginal line takes whatever units remain (divisible).
  Returns `{allocated :: [{line, allocated_qty}], marginal_price :: Decimal.t() | nil}`
  where `marginal_price` is the lowest winning unit price.
- **`resolve/3`** — parameterized by a per-format `price_rule` fun (as `Sealed.resolve/3`
  takes `rank` + `pricing`). Runs `allocate/2`, applies `price_rule` to produce the
  `%Gavel.Allocation{}`, sets `status: :closed, phase: :resolved`, emits
  `{:cleared, %{allocation: allocation}}`.

## 3. Sealed formats — `Gavel.Types.MultiUnit.{UniformPrice, PayAsBid, Vickrey}`

All `kind: :sealed`; all delegate `place_bid/3` and `resolve/2` to the engine; they
differ **only in the price rule**:

| Module | `amount` each winner pays |
|---|---|
| `UniformPrice` | `quantity × clearing_price`, where `clearing_price = max(reserve, lowest winning unit price)`. Top-level `clearing_price` populated. |
| `PayAsBid` | `quantity × own unit price`, summed across that bidder's winning lines. `clearing_price: nil`. |
| `Vickrey` | Opportunity cost `W_-i(Q) - W_-i(Q - q_i)`: others' best achievable welfare on `Q` units minus on `Q - q_i` units, where `W` sums `unit_price * qty` over winning lines. Truthful generalization of the single-unit second-price rule. `clearing_price: nil`. |

`validate_config/1` for each requires `:quantity` present and positive; `:reserve_price`
optional.

## 4. Ausubel ascending clock — `Gavel.Types.MultiUnit.Ausubel`

`@behaviour Gavel.Type` + `@behaviour Gavel.Type.Clock`, plus the new optional
`reduce_demand/3` callback.

- **Config:** `:quantity` (Q), `:start_price`, `:increment`, `:tick_interval_ms`;
  optional `:reserve_price`. `kind: :clock`.
- **`start_clock/1`** seeds `extra: %{price: start_price, demand: %{}, clinched: %{}}`,
  where `demand` maps `bidder => current demanded qty` and `clinched` maps
  `bidder => [%{quantity, price}]`.
- **`place_bid/3`** = entry: registers a bidder's **initial demand** (`bid.quantity`);
  `amount` is unused. Emits `{:bid_placed, %{bidder: bidder}}`.
- **`reduce_demand/3`** (new optional callback): a bidder lowers their demand. Must be
  **weakly decreasing** (`{:error, :demand_increase}` otherwise). Emits
  `{:demand_reduced, %{bidder: bidder, quantity: new_qty}}`.
- **`tick/2`**: raise `price` by `:increment`, then recompute **clinching** at the new
  price: for each bidder `i`, `cumulative_clinch_i = max(0, Q - sum_{j!=i} demand_j)`; the
  increase since the previous clinch total is clinched at the **current price** and
  appended to `clinched[i]`, emitting `{:clinched, %{bidder, quantity, price}}`.
  Ends (transitions to `resolve`) when `sum(demand) <= Q`; `closes_at`, if set, is a backstop.
- **`resolve/2`**: build `%Gavel.Allocation{}` — each winner's `quantity` = total units
  clinched, `amount` = `sum(clinch_qty * clinch_price)`. `clearing_price: nil` (per-unit
  prices differ). Reproduces the VCG outcome dynamically.

## 5. Runtime / API

- **`Gavel.place_bid/4`** — `place_bid(id, bidder, amount, opts \\ [])` where `opts` may
  carry `:quantity`. **Arity-3 stays** (backward compatible). `:quantity` threads through
  the existing keyword list `Server.place_bid/2` already accepts, into `Bid.new/1`.
- **`Gavel.reduce_demand/3`** -> `Server.reduce_demand` -> dispatches to the type's optional
  `reduce_demand/3`, guarded by `function_exported?`, exactly like `drop_out`.
- **`Gavel.Type`** gains an optional `reduce_demand/3` callback alongside `drop_out/3`
  (single-format interactive action — same category as drop-out, so an optional callback,
  not a new behaviour).
- Store/PubSub wiring unchanged. New events: `{:cleared, %{allocation}}` (all formats at
  resolve); `{:demand_reduced, …}` and `{:clinched, …}` (Ausubel).

## 6. Edge cases (locked)

- **Undersubscription** (qualifying demand < Q): all qualifying bids win; uniform clearing
  = `max(reserve, lowest winning price)`; leftover units unsold (`units_sold < units_offered`).
- **Reserve**: bids below reserve never win; partial sale if qualifying demand < Q; if zero
  qualify, `units_sold: 0` and `lines: []`.
- **Marginal ties**: strict earliest-`placed_at` priority; the crossing line takes the
  remainder. No pro-rata.

## 7. Module layout

```
lib/gavel/allocation.ex                         Gavel.Allocation result struct
lib/gavel/types/multi_unit.ex                   Gavel.Types.MultiUnit (shared sealed engine)
lib/gavel/types/multi_unit/uniform_price.ex     Gavel.Types.MultiUnit.UniformPrice
lib/gavel/types/multi_unit/pay_as_bid.ex        Gavel.Types.MultiUnit.PayAsBid
lib/gavel/types/multi_unit/vickrey.ex           Gavel.Types.MultiUnit.Vickrey
lib/gavel/types/multi_unit/ausubel.ex           Gavel.Types.MultiUnit.Ausubel (clock)
```

Touched existing files: `lib/gavel/bid.ex` (+`:quantity`), `lib/gavel/auction.ex`
(dump/load for `quantity` and `%Gavel.Allocation{}`), `lib/gavel/type.ex`
(+optional `reduce_demand/3`), `lib/gavel/server.ex` (+`reduce_demand` dispatch),
`lib/gavel.ex` (+`place_bid/4`, `reduce_demand/3`).

## 8. Testing strategy

- **Property tests (StreamData) for invariants:**
  - `sum(allocated quantity) <= Q` for every format and input.
  - UniformPrice: all winners pay one clearing price, and clearing price `>= reserve`.
  - PayAsBid: each winner's `amount == sum(qty * own unit price)`.
  - Vickrey: a bidder's Vickrey payment `<=` their pay-as-bid payment (truthful <= first-price).
  - Reserve: no winning line has `unit_price < reserve`.
  - Ausubel: total clinched per bidder == final demand; clinch prices non-decreasing.
- **Example tests** per format (including the worked VCG example: 2 units, bids 10/8/5 ->
  both winners pay 5).
- **Ausubel sequence test**: entry -> ticks -> `reduce_demand` -> clinch records -> resolve.
- **Runtime tests**: `place_bid/4` with `:quantity`; `reduce_demand` over a live clock;
  the existing ETS-recovery test extended to a multi-unit auction so `%Gavel.Allocation{}`
  and `quantity` round-trip through `dump`/`load`.

## Open questions / future work

- UniformPrice clearing rule is fixed to "lowest winning price"; a `:highest_losing`
  variant could be a config option later if demanded.
- Multi-unit Dutch (sequential flower-clock and/or uniform stop-price) remains a possible
  later addition; the `Gavel.Type.Clock` seam already accommodates it.
