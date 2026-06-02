# CLAUDE.md — Gavel

A multi-format auction library for Elixir (English, Dutch, Vickrey, sealed
first-price, reverse, Japanese). Hex-publishable, standalone repo.

## Architecture

Two layers — keep them separate:

1. **Pure functional core** — structs + deterministic functions, **no
   processes**, only dependency is `Decimal`.
   - `Gavel.Auction` — state struct + lifecycle.
   - `Gavel.Bid` — a bid.
   - `Gavel.Type` — the behaviour each format implements (`kind/0`,
     `validate_config/1`, `place_bid/3`, `resolve/2`, `drop_out/3`, …).
   - `Gavel.Types.{English, Dutch, Vickrey, SealedFirstPrice, Reverse,
     Japanese}` — one module per format. Shared logic in
     `lib/gavel/types/helpers.ex`. Clock helpers in `Gavel.Type.Clock`.
2. **Opt-in OTP runtime** — a GenServer per auction with timers, crash
   recovery, and event broadcasts, built on top of the core.
   - `Gavel` — thin public API (`start_auction/1`, `place_bid/3`,
     `set_max_bid/3`, `accept/2`, `drop_out/2`, `get/1`, `close/1`).
   - `Gavel.Server` — GenServer + `via/1` Registry tuples.
   - `Gavel.Application` — DynamicSupervisor + Registry.
   - `Gavel.Store` behaviour with `Gavel.Store.ETS` (default, survives process
     crash) and `Gavel.Store.DETS` (survives node restart). Implement the
     behaviour to back auctions with Postgres/Redis without Gavel depending on
     your database.

Consumers can use the core alone (owning their own concurrency/timing/storage)
or adopt the batteries-included runtime. Mechanism rules live **only** in the
type modules; the server is a thin shell that calls into them.

## Conventions

- All money is `Decimal` — never floats. Compare with `Decimal.compare/2`, not
  `==`/`>`.
- A format's terminal `result` is `{:sold, bidder, price}` or `:no_sale`.
- Actions return `{:ok, auction, events}` where `events` is a list of
  `{event_name, payload}` pairs. The runtime rebroadcasts these over PubSub on
  topic `"auction:<id>"` as `{:gavel, auction_id, {event, payload}}` (set
  `config :gavel, pubsub: MyApp.PubSub`).
- `:kind` is one of `:open | :sealed | :clock` and drives runtime timer
  behaviour.

## Commands

    mix test                 # ExUnit; property tests use stream_data
    mix coveralls            # coverage (preferred_env handles MIX_ENV)
    mix credo                # linter (.credo.exs)
    mix dialyzer             # type checking (dialyxir)
    mix format               # formatter (.formatter.exs)
    mix docs                 # ex_doc

`elixirc_paths` adds `test/support` in the test env.

## Where things are

- `lib/gavel.ex` — public API.
- `lib/gavel/` — core + runtime.
- `lib/gavel/types/` — the six format modules + helpers.
- `lib/gavel/store/` — ETS/DETS stores.
- `docs/design.md` — the authoritative design doc (architecture, mechanism
  rules per format, non-goals). Read it before changing mechanism behaviour.
- `test/` — tests, including property-based invariants.

## Notes

- v1 is single-lot, single-winner, single-node. Multi-item / combinatorial /
  double auctions are out of scope. Commit-reveal sealed bidding is designed-for
  but not implemented (see `docs/design.md`).
- The `live_gavel` app (sibling repo) is a Phoenix LiveView showcase that
  depends on this library.
