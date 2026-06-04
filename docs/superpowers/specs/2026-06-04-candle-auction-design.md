# Candle auction — design spec

**Date:** 2026-06-04
**Status:** Approved, pending implementation plan
**Adds:** `Gavel.Types.Candle` — a seventh auction format.

## Summary

A **candle auction** is an open ascending auction with a two-stage random
ending. It reuses English's bidding mechanics entirely (increments, proxy/max
bids, reserve) and adds only the random close:

1. The auction runs openly until a public, announced time `notice_at` (`t`).
2. At `t`, every participant is notified simultaneously (`:final_call`
   broadcast). The auction stays open.
3. The auction then closes at `t + d`, where `d` is a **hidden** random delay
   drawn from `[min_delay, max_delay]`. The leading bid at the close wins.

Every bid placed in the burn-down window `[t, t+d]` counts; **nothing is ever
voided**. The format is forward-looking and transparent: everyone receives the
same warning, and the only hidden quantity is exactly when — within an announced
bound — the candle goes out. It is snipe-proof because a close you cannot see
cannot be sniped.

This is the transparent alternative to the classic "retroactive random
termination" candle (which voids post-cutoff bids after the fact); that variant
was considered and rejected in favour of this one.

## Why it fits Gavel

- **Pure deterministic core preserved.** The core never calls `:rand` or
  `DateTime.utc_now/0`. The random delay is *injected* into the core exactly the
  way `now` already is (see the new `on_notice/3` callback). The runtime supplies
  real randomness; tests and core-only consumers supply their own.
- **Maximal reuse.** Bidding and winner determination are English's, reached
  through the existing shared `Gavel.Types.Helpers`. Candle adds only the
  notice/close lifecycle.
- **Mechanism rules stay in the type module.** The server remains a thin shell.

## Config keys

This is the first format with a non-trivial `validate_config/1`.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `:notice_at` | `DateTime` | **Yes** | When the `:final_call` warning fires (`t`). |
| `:max_delay` | integer (seconds) | **Yes** | Upper bound of the burn-down delay after `t`. |
| `:min_delay` | integer (seconds) | No (default `0`) | Guaranteed burn before the candle can go out. |
| `:start_price` | `Decimal` | No | Floor for the first visible bid (English semantics). |
| `:min_increment` | `Decimal` | No | Minimum raise over the current price (English semantics). |
| `:reserve_price` | `Decimal` | No | Minimum acceptable winning price; below it → `:no_sale`. |

`validate_config/1` rejects:

- missing `:notice_at` or `:max_delay`,
- negative `:min_delay` or `:max_delay`,
- `:min_delay > :max_delay`.

`:anti_snipe` is not supported (the format is inherently snipe-proof).

## `Gavel.Types.Candle`

- `kind/0` → `:open`. `:phase` is `nil` (no sealed sub-state).
- `place_bid/3` → delegates to `Gavel.Types.English.place_bid/3` for all bidding
  logic, with one authoritative guard added: reject with
  `{:error, :auction_closed}` when `now` is at or after `extra.secret_close`.
  This closes the race between the runtime's close timer and a late `place_bid`
  call, and makes the close boundary testable in the pure core. Before the
  notice fires, `secret_close` is `nil` and bidding behaves exactly like English.
- `on_notice/3` (new optional behaviour callback — see below) → sets
  `extra.secret_close = notice_at + delay_seconds` and emits
  `{:final_call, %{notice_at: t, max_delay: m}}`.
- `resolve/2` → highest bid clearing the reserve (via `Helpers.highest/1` +
  `Helpers.clears_reserve?/2`, the same logic English uses), set `status:
  :closed`, emit `{:closed, %{result: result, closed_at: secret_close}}`.

## New behaviour callback: `c:Gavel.Type.on_notice/3`

```elixir
@callback on_notice(Auction.t(), delay_seconds :: non_neg_integer(), now :: DateTime.t()) ::
            {:ok, Auction.t(), events()}
@optional_callbacks on_notice: 3   # (added alongside the existing drop_out: 3)
```

Pure. The random delay is **injected** as `delay_seconds`, mirroring how `now`
is injected throughout the core. Only `Gavel.Types.Candle` implements it; the
other six formats are untouched.

## Runtime — `Gavel.Server` changes

1. **Notice timer.** Arm a `:notice` timer when `config.notice_at` is a
   `%DateTime{}` **and** `extra.secret_close` is still `nil`. The `secret_close`
   guard means the notice never re-fires after a crash/rehydrate once the candle
   has been lit.
2. **On `:notice`.** Draw `d = min_delay + :rand` such that `d ∈ [min_delay,
   max_delay]`, call `auction.type.on_notice(auction, d, now)`, `commit/3` the
   result (persist + broadcast `:final_call`), then arm the close timer from the
   updated auction.
3. **Effective close.** Generalize `schedule_close/1` to read the effective close
   as `extra[:secret_close] || closes_at`. One-line change; no other type sets
   `secret_close`, so they are unaffected. This also gives correct crash recovery
   for free.

`Gavel.start_auction/1` and the open path are unchanged — the randomness
injection point is the notice handler, not open.

## Events

| Event | When |
|-------|------|
| `{:bid_placed, %{bid: bid}}` | A bid is accepted (from English) |
| `{:outbid, %{bidder: prior}}` | The leader changes (from English) |
| `{:final_call, %{notice_at: t, max_delay: m}}` | At `notice_at` |
| `{:closed, %{result: result, closed_at: secret_close}}` | At the real close |

## Persistence

No new serialization code. `secret_close` is a `DateTime` stored in `extra`,
which `Auction.dump/1`/`load/1` already round-trip as `{:dt, …}`. `notice_at`
(config `DateTime`) and the integer delays round-trip via the existing
config encoders. Crash recovery re-arms the correct timer based on whether
`secret_close` is set.

## Testing strategy

**Core (deterministic — injected `now` and injected `delay_seconds`):**

- `on_notice/3` sets `secret_close = notice_at + delay` and emits `:final_call`.
- A bid with `now ≥ secret_close` is rejected with `:auction_closed`.
- The leading bid at close wins; reserve not met → `:no_sale`.
- Every bid placed during the `[t, t+d]` window counts toward the result.
- Property: the winner is always the highest bid placed before `secret_close`;
  the reserve invariant holds.

**Runtime (`Gavel.Server`):**

- `:final_call` is broadcast at `notice_at`.
- Auto-close fires at the drawn `secret_close`.
- ETS-recovery: crash after the notice → rehydrates `secret_close` → still closes
  correctly and does not re-fire the notice.

**Regression:** English's existing test suite must stay green — Candle reuses
English unchanged, and English itself is not modified by this work.

## Docs

- `@moduledoc` for `Gavel.Types.Candle` with the config table and a runnable
  example.
- Add a Candle row to the format table in `docs/design.md`.
- Document `on_notice/3` in the `Gavel.Type` behaviour docs.

## Non-goals

- No retroactive bid voiding (the rejected variant).
- No `:anti_snipe` support for this format.
- No change to the other six formats beyond the additive, optional `on_notice/3`
  callback declaration.
