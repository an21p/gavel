# English auction: a bidder cannot pump their own price

**Date:** 2026-06-02
**Repos affected:** `gavel` (core: `Gavel.Types.English`), `live_gavel` (gavelui — test only)

## Problem

In an English (open ascending) auction, the **current highest bidder can push
the visible price higher by acting again**, which should never happen — you
cannot bid against yourself. Two reported symptoms, one root cause:

1. The current leader places another bid → the visible price rises by one
   increment.
2. The current leader sets a max bid after a plain bid → the visible price rises
   by one increment.

### Root cause

`Gavel.Auction.put_bid/2` **appends** every bid; it never merges per bidder. So
a repeat bidder accumulates multiple entries in `auction.bids`. The proxy
recompute (`Gavel.Types.English.apply_contested/5`) then treats the bidder's
**own earlier entry as the runner-up competitor** and advances the leader's
visible amount to `runner_ceiling + min_increment` — i.e. the bidder outbids
themselves. `set_max_bid` is just a special case: gavelui's
`Gavel.Server.set_max_bid/3` sends `amount = max_amount = max`, creating a second
self-entry for the bidder.

A secondary effect: because `auction.bids` holds duplicate per-bidder entries,
the gavelui leaderboard (`LiveGavel.Showcase.view_model/1` → `leaderboard/2`)
shows multiple rows for one bidder.

## Decision

Adopt the invariant: **the visible price is driven only by competition between
distinct bidders; a bidder's own action never moves their own visible price —
neither up (pump) nor down (drop).** A bidder's own re-bid or max raise only
updates their hidden ceiling (proxy max). This is the eBay proxy model.

The fix is **English-only**. `Auction.put_bid/2` is shared by other formats
(sealed, vickrey, reverse, the resolve property test) and is left unchanged.

### Approaches considered

- **A (chosen) — merge-per-bidder + ratchet, inside `English.place_bid/3`.**
  Collapse each bidder to one standing entry (highest ceiling, earliest
  `placed_at`), then floor each bidder's recomputed visible amount at its prior
  value. Removes the phantom self-competitor and prevents the lone-proxy drop.
  Self-contained; existing recompute/resolve/admissibility untouched.
- **B — bidder-aware recompute (keep appending; ignore same-bidder when
  choosing the runner-up).** Rejected: the bids list keeps growing with
  duplicates, the leaderboard still needs display-time dedup, and the recompute
  logic gets more tangled.
- **C — reject leader re-bids with an error.** Rejected by the user in
  brainstorming in favour of the silent eBay model (raise ceiling, no pump).

## Changes

### `gavel` — `Gavel.Types.English.place_bid/3`

Two surgical additions; the `with` guard chain (`ensure_open`,
`check_admissible`) is unchanged.

1. **Capture prior state before mutating:**
   - `prior_leader = Helpers.highest(auction.bids)` (already captured today as
     `prior`, used for the `:outbid` event — keep).
   - `prior_visible = Map.new(auction.bids, &{&1.bidder, &1.amount})` — each
     bidder's current visible amount, keyed by bidder.

2. **Merge instead of append** (new private `merge_bid/2`): replace the
   incoming bidder's existing standing entry (if any) rather than appending.
   The merged entry keeps:
   - `max_amount` = the higher of the existing ceiling and the new ceiling
     (`dec_max(ceiling(existing), ceiling(new))`), stored as `max_amount` so the
     standing entry is represented by its ceiling. A bidder can never *lower*
     their ceiling via a smaller re-bid.
   - `placed_at` = the earlier of the two (`existing` vs `new`) — preserves
     tie-break priority for a bidder who committed first.
   - other fields taken from the new bid.
   A first-time bidder is appended as today.

3. **Ratchet after recompute** (new private `ratchet/2`): after
   `recompute_visible_amounts/1`, set each bid's `amount` to
   `dec_max(recomputed_amount, prior_visible[bidder])` (no floor for first-time
   bidders). This keeps a leader's price steady when they raise their own max
   (recompute would otherwise drop a lone proxy leader to `start_price`), while
   still letting a genuine competitor push the price up. The result never
   exceeds the bidder's own ceiling (both inputs are `<= ceiling`).

New `place_bid/3` body shape:

```elixir
def place_bid(%Auction{} = auction, %Bid{} = bid, %DateTime{} = now) do
  with :ok <- Helpers.ensure_open(auction),
       :ok <- check_admissible(auction, bid) do
    prior_leader = Helpers.highest(auction.bids)
    prior_visible = Map.new(auction.bids, &{&1.bidder, &1.amount})

    auction =
      auction
      |> merge_bid(bid)
      |> recompute_visible_amounts()
      |> ratchet(prior_visible)

    {auction, extend_events} = Helpers.maybe_extend(auction, now)

    events =
      [{:bid_placed, %{bid: bid}}] ++
        outbid_event(prior_leader, Helpers.highest(auction.bids)) ++
        extend_events

    {:ok, auction, events}
  end
end
```

Unchanged: `recompute_visible_amounts/1`, `apply_contested/5`,
`lone_leader_amount/2`, `check_admissible/2`, `resolve/2`, `outbid_event/2`,
`Auction.put_bid/2`.

### `live_gavel` (gavelui) — no production code change

`LiveGavel.Showcase` and `Gavel.Server` pass straight through the engine. The
per-bidder dedup makes `leaderboard/2` yield one row per bidder automatically.
Only a test is added.

## Behavioural outcomes

- Current leader raises max or re-bids → ceiling rises, **visible price
  unchanged**. (Both reported symptoms.)
- A **different** bidder bids → proxy war advances the price exactly as before.
- `auction.bids` holds **one entry per bidder**; the leaderboard shows one row
  per bidder.

## Edge cases / explicit decisions

- **Lone proxy leader** still shows `start_price` on their *first* max bid
  (existing test: "a lone proxy bidder leads at the starting amount"). The
  ratchet only floors at a *prior* visible amount, which a first-time bidder
  doesn't have.
- **Set max after a plain bid:** prior visible (e.g. 100) is preserved by the
  ratchet; recompute alone would drop a now-proxy lone leader to `start_price`.
- **Sub-increment leader re-bid:** still rejected as `:below_min_increment` by
  the unchanged `check_admissible/2` (it compares the incoming ceiling to the
  visible price). It never pumps; rejection is acceptable.
- **Lowering your own max:** not possible — `merge_bid/2` keeps the higher
  ceiling.

## Tests

### `gavel/test/gavel/types/english_test.exs`
- The current leader bidding again does **not** raise the visible price.
- Setting a max after a plain bid does **not** raise the visible price (and the
  bidder's ceiling rises so they can still win a later proxy war).
- After a leader raises their max, a genuine higher rival still triggers the
  normal proxy advance, and the original leader is correctly outbid / re-leads.
- `auction.bids` has exactly one entry per bidder after repeated bids by the
  same bidder.
- Existing proxy tests stay green (lone proxy at start, higher max wins at one
  increment, proxy capped at own max).

### `live_gavel/test/live_gavel/showcase_test.exs`
- Start an English showcase, place a bid as a persona, then set a higher max as
  the **same** persona: assert `Showcase.get(id).current_price` is unchanged and
  the leaderboard has a single row for that bidder.

## Out of scope

- Other auction formats (sealed, vickrey, reverse, Japanese) and
  `Auction.put_bid/2`.
- Anti-snipe, reserve, and resolve semantics.
- Any gavelui UI/markup change beyond the added test.
