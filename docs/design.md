# Gavel — a multi-format auction library for Elixir

**Date:** 2026-06-01
**Status:** Design approved, pending spec review
**Placement:** Brand-new standalone, Hex-publishable library in its own git repo (not part of the jmbld monorepo).

## Summary

`Gavel` is an Elixir library for running auctions of several classic formats. It is built in two
layers: a **pure functional core** (structs + deterministic functions, no processes) and an
**opt-in OTP runtime** (a GenServer per auction with timers, crash recovery, and event broadcasts)
built on top of that core. Consumers can use just the core (owning their own concurrency, timing,
and storage) or adopt the batteries-included runtime.

The design mirrors the `jmbld_engine` philosophy: pure rules modules at the bottom, a thin process
shell on top, ETS for crash recovery.

## Goals

- Support six auction formats with correct mechanism rules (see §3).
- Keep the core pure and deterministic so auction-theory invariants can be property-tested.
- Keep the library dependency-light; do not force consumers into a database or a web framework.
- Shape the sealed-auction state machine so commit-reveal can be added later without a rewrite.

## Non-goals (v1)

- Commit-reveal sealed bidding (designed-for, not implemented — see §3).
- Multi-item / combinatorial / double auctions (single lot, single winner per auction).
- A built-in database adapter (the `Store` behaviour makes one trivial to add later).
- Distributed / multi-node auction processes (single-node runtime; ETS/DETS are node-local).

## 1. Architecture

```
Gavel              ← thin public API (start_auction, place_bid, set_max_bid, accept, drop_out, get, close)
├─ Gavel.Core      ← PURE: structs + functions, no processes; only dependency is Decimal
│   ├─ Gavel.Auction        (state struct + lifecycle)
│   ├─ Gavel.Bid
│   ├─ Gavel.Type           (behaviour the six types implement)
│   └─ Gavel.Types.{English, Dutch, Vickrey, SealedFirstPrice, Reverse, Japanese}
└─ Gavel.Runtime   ← OTP shell built ON the core
    ├─ Gavel.Server         (GenServer per auction: timers, Store persistence, PubSub)
    ├─ Gavel.Supervisor     (DynamicSupervisor for auction processes)
    ├─ Gavel.Registry       (via-tuple lookup by auction id)
    └─ Gavel.Store          (persistence behaviour + ETS and DETS adapters)
```

The core is fully usable standalone. The runtime is opt-in.

## 2. Pure core — key design move

Every core function takes an **explicit `now` (`DateTime`) argument**. The core never calls
`DateTime.utc_now/0`. This makes it deterministic and property-testable; the runtime injects real
time, tests inject fixed time.

`Gavel.Type` is a **behaviour** implemented once per format, with callbacks:

- `validate_config/1` — reject invalid setups at creation (raises / returns error before any process starts).
- `place_bid/3` → `{:ok, auction, events} | {:error, reason}`.
- `tick/2` — advance clock-driven types (Dutch descends, Japanese ascends) at a given time.
- `resolve/2` — at close, compute `{:sold, winner, price} | :no_sale`.

This is the same spirit as `jmbld_engine`'s pure `Rules.{Single,Multi,Coop}` modules. The core
*returns* an events list from `place_bid`/`tick`/`resolve`; it never broadcasts anything itself.

## 3. The six auction formats

| Type | Bids visible? | Winner | Price paid | Driver |
|---|---|---|---|---|
| **English** | yes | highest | own bid | bids + min increment + proxy/max |
| **Dutch** | n/a | first to `accept` | clock price at accept | descending clock `tick` |
| **Vickrey** | hidden till close | highest | **2nd**-highest bid | sealed → resolve |
| **SealedFirstPrice** | hidden till close | highest | own bid | sealed → resolve |
| **Reverse** | hidden till close | **lowest** | own bid | sealed procurement |
| **Japanese** | yes | last standing | exit price of 2nd-last drop-out | ascending clock + `drop_out` |

`SealedFirstPrice` was not in the originally named list but is folded in: Vickrey already requires the
full sealed pipeline (collect hidden bids → reveal at close → pick winner), so first-price sealed is a
payment-rule variant that comes nearly free.

**Commit-reveal forward-compatibility:** the sealed types (Vickrey, SealedFirstPrice, Reverse) carry a
`phase: :bidding | :revealing | :resolved` field. In v1's trusted-store mode the `:revealing` phase is
collapsed (auto-reveal at close). The field exists so a future commit-reveal mode slots in as a second
mode without rewriting the struct.

## 4. Cross-cutting features (all in the core, all opt-in per auction)

- **Reserve price** — `resolve` returns `:no_sale` when the best qualifying bid is below the reserve.
  Reserve failure is *not* a bid-time error; it surfaces only at resolution.
- **Minimum increment** — open/ascending types reject `{:error, :below_min_increment}`.
- **Anti-snipe auto-extend** — an `closes_at` field; a bid landing within the configured window pushes
  `closes_at` out by a configured amount and emits an `:extended` event. Modeled purely in the core;
  the runtime's timer re-arms on extend.
- **Proxy / max bids** — bidders may set a hidden `max_amount`. The core keeps the proxy bidder as the
  leader at one minimum-increment above the runner-up, never exceeding their `max_amount`, and resolves
  increment wars between competing maxes. Ties broken by earliest `placed_at`.

## 5. Money & identity

- **Amounts: `Decimal`** everywhere (dependency: `decimal`). All comparisons go through `Decimal.compare/2`.
- **Bidder identity: opaque caller-supplied term** (integer, string, etc.). The library never interprets it.
- **Tie-break: earliest `placed_at` wins.**

## 6. OTP runtime

- `Gavel.start_auction(config)` spawns a `Gavel.Server` under the `DynamicSupervisor`, registered by id
  in `Gavel.Registry`.
- Public API: `place_bid/3`, `set_max_bid/3`, `accept/2` (Dutch), `drop_out/2` (Japanese), `get/1`,
  `close/1`.
- The `Server` arms `Process.send_after` timers for `closes_at`, for clock ticks (Dutch/Japanese), and
  re-arms the close timer on anti-snipe extension.
- After every state transition the server persists the auction's dumped state via the configured
  `Gavel.Store` (default ETS), then broadcasts events.

### Events — Phoenix.PubSub, optional

The core returns an events list; the `Server` is the only thing that broadcasts. If a Phoenix.PubSub is
configured, the server broadcasts on topic `"auction:#{id}"`; if none is configured it silently no-ops,
so core-only / PubSub-less consumers are never forced into the dependency (`phoenix_pubsub`).

Event messages: `:bid_placed`, `:outbid`, `:price_dropped` (Dutch tick), `:extended` (anti-snipe),
`:closed` (with result), `:no_sale`.

### Persistence — ETS always-on + pluggable Store

Two distinct concerns are kept separate:

| Concern | Mechanism |
|---|---|
| **Process-crash recovery** (supervisor restarts one auction's GenServer) | ETS — in-VM, microsecond, always on |
| **Node-restart / durability** (deploy, VM crash, power loss) | a `Gavel.Store` adapter that hits disk |

- The core exposes pure `Auction.dump/1` → plain term and `Auction.load/1` ← term. No storage opinion.
- `Server.init` rehydrates from the Store so a crashed auction process resumes its prior state (the
  `jmbld_engine` ETS pattern).
- `Gavel.Store` is a **behaviour** with `save(id, dumped)`, `load(id)`, `delete(id)`. Built-in adapters:
  - `Gavel.Store.ETS` — default, ephemeral, named public table for cross-process-restart recovery.
  - `Gavel.Store.DETS` — file-backed, single-node, zero-dependency durability across node restarts.
  - Consumers may implement their own (e.g. `Store.Postgres` persisting `dump/1` to a `jsonb` column)
    *without `Gavel` depending on Ecto*. No built-in DB adapter ships in v1 (YAGNI for a generic library).

## 7. Error handling

The core never raises on a bad *bid* — it returns `{:error, reason}` with atom reasons:
`:auction_closed`, `:below_min_increment`, `:bid_too_low`, `:unknown_bidder`, `:wrong_phase`, etc.
It raises only on programmer error (invalid config at `start_auction`/`validate_config`). Reserve
failure is not a bid error; it surfaces as `:no_sale` at resolve.

## 8. Testing strategy

- **Core:** `StreamData` property tests for auction-theory invariants —
  - Vickrey winner pays exactly the second-highest bid;
  - a reserve always yields `:no_sale` when the best bid is below it;
  - minimum increment is always enforced on open types;
  - a proxy bid never exceeds its `max_amount`;
  - ties resolve to the earliest `placed_at`;
  plus example tests per format. All deterministic via injected `now`.
- **Runtime:** GenServer tests asserting timer-driven close, that configured PubSub messages are
  received, and an **ETS-recovery test** (kill the process, assert it rehydrates identical state).
- **Tooling** mirrors the jmbld repo conventions: `credo --strict`, `ex_doc`, `dialyxir`, ExCoveralls.

## Dependencies

- Runtime: `decimal` (core), `phoenix_pubsub` (runtime, optional in effect).
- Dev/test: `stream_data`, `ex_doc`, `credo`, `dialyxir`, `excoveralls`.

## Open questions / future work

- Commit-reveal sealed mode (state machine already shaped for it).
- Built-in `Store.Postgres`/`Store.Redis` adapters if demand appears.
- Distributed runtime (multi-node registry + replicated store) — explicitly out of scope for v1.
