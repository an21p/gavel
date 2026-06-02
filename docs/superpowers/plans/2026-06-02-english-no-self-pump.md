# English No-Self-Pump Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In an English auction, the current highest bidder can no longer raise their own visible price by bidding again or setting a max — the visible price moves only when a different bidder competes.

**Architecture:** Two surgical additions inside `Gavel.Types.English.place_bid/3`: (1) `merge_bid/2` collapses each bidder to one standing entry (higher ceiling, earliest `placed_at`), removing the phantom self-competitor; (2) `ratchet/2` floors each bidder's recomputed visible amount at its prior value, so a leader raising their own max neither pumps nor drops their price. `recompute_visible_amounts/1`, `resolve/2`, `check_admissible/2`, and the shared `Auction.put_bid/2` are unchanged. gavelui (`live_gavel`) needs no production change — it flows through the engine, and per-bidder dedup makes the leaderboard show one row per bidder automatically.

**Tech Stack:** Elixir, ExUnit, Decimal. Two sibling repos: `gavel` (core, `~/apps/gavel`, on branch `main`) and `live_gavel` (gavelui, `~/apps/live_gavel`, on branch `master`).

**Spec:** `~/apps/gavel/docs/superpowers/specs/2026-06-02-english-no-self-pump-design.md`

---

## File Structure

- `gavel/lib/gavel/types/english.ex` — `place_bid/3` rewired; new private `merge_bid/2`, `ratchet/2`, `earliest/2`. **Core change.**
- `gavel/test/gavel/types/english_test.exs` — new no-self-pump tests; existing proxy tests must stay green.
- `live_gavel/test/live_gavel/showcase_test.exs` — end-to-end no-pump test.

All `git` commits use the project identity:
`git -c user.email="antonis@pishias.com" -c user.name="Antonis" commit ...`

---

## Task 1: English `place_bid/3` — merge per bidder + ratchet

**Files:**
- Modify: `~/apps/gavel/lib/gavel/types/english.ex` (`place_bid/3` at lines 110-124; add private helpers near `dec_max/2` ~line 222)
- Test: `~/apps/gavel/test/gavel/types/english_test.exs`

- [ ] **Step 1: Add the failing tests**

Append these tests to `test/gavel/types/english_test.exs`, inside the module before the final `end` (they use the existing `open_auction/1`, `bid/4`, `proxy/4`, and `Helpers` already imported at the top):

```elixir
describe "a bidder cannot pump their own price" do
  test "the current leader bidding again does not raise the visible price" do
    a = open_auction(%{min_increment: Decimal.new(10), start_price: Decimal.new(10)})
    {:ok, a, _} = bid(a, 1, "50")
    before = Helpers.highest(a.bids).amount

    {:ok, a, _} = bid(a, 1, "70", 1)
    leader = Helpers.highest(a.bids)

    assert leader.bidder == 1
    assert Decimal.equal?(leader.amount, before)
    assert length(a.bids) == 1
  end

  test "setting a max after a plain bid does not raise the visible price" do
    a = open_auction(%{min_increment: Decimal.new(10), start_price: Decimal.new(10)})
    {:ok, a, _} = bid(a, 1, "50")

    {:ok, a, _} = proxy(a, 1, "300", 1)
    leader = Helpers.highest(a.bids)

    assert leader.bidder == 1
    assert Decimal.equal?(leader.amount, Decimal.new(50))
    assert Decimal.equal?(leader.max_amount, Decimal.new(300))
    assert length(a.bids) == 1
  end

  test "a genuine rival still advances the price after the leader raised their own max" do
    a = open_auction(%{min_increment: Decimal.new(10), start_price: Decimal.new(10)})
    {:ok, a, _} = bid(a, 1, "50")
    {:ok, a, _} = proxy(a, 1, "300", 1)
    {:ok, a, _} = proxy(a, 2, "100", 2)

    leader = Helpers.highest(a.bids)
    runner = Enum.find(a.bids, &(&1.bidder == 2))

    assert leader.bidder == 1
    assert Decimal.equal?(leader.amount, Decimal.new(110))
    assert Decimal.equal?(runner.amount, Decimal.new(100))
  end

  test "repeated bids by the same bidder keep a single standing entry" do
    a = open_auction(%{min_increment: Decimal.new(10)})
    {:ok, a, _} = bid(a, 1, "20")
    {:ok, a, _} = bid(a, 1, "40", 1)
    {:ok, a, _} = proxy(a, 1, "200", 2)

    assert length(a.bids) == 1
    assert hd(a.bids).bidder == 1
  end
end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `cd ~/apps/gavel && mix test test/gavel/types/english_test.exs -v`
Expected: the four new tests FAIL — under current code the same bidder's prior
entry acts as a runner-up, so the visible price pumps (e.g. 50 → 60/70, or
150 → 160) and `length(a.bids)` is 2+, not 1.

- [ ] **Step 3: Rewire `place_bid/3`**

In `lib/gavel/types/english.ex`, replace the current `place_bid/3` body (lines 110-124):

```elixir
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
```

with:

```elixir
  def place_bid(%Auction{} = auction, %Bid{} = bid, %DateTime{} = now) do
    with :ok <- Helpers.ensure_open(auction),
         :ok <- check_admissible(auction, bid) do
      prior = Helpers.highest(auction.bids)
      prior_visible = Map.new(auction.bids, &{&1.bidder, &1.amount})

      auction =
        auction
        |> merge_bid(bid)
        |> recompute_visible_amounts()
        |> ratchet(prior_visible)

      {auction, extend_events} = Helpers.maybe_extend(auction, now)

      events =
        [{:bid_placed, %{bid: bid}}] ++
          outbid_event(prior, Helpers.highest(auction.bids)) ++
          extend_events

      {:ok, auction, events}
    end
  end
```

- [ ] **Step 4: Add the private helpers**

In `lib/gavel/types/english.ex`, immediately after the `dec_max/2` definition (currently line 222: `defp dec_max(a, b), do: ...`), add:

```elixir
  # Each bidder holds at most one standing bid. A re-bid replaces the bidder's
  # existing entry, keeping the higher ceiling (stored as max_amount) and the
  # earlier placed_at so a bidder who committed first keeps tie-break priority.
  # This stops a bidder's own earlier bid from acting as a phantom runner-up in
  # recompute_visible_amounts/1.
  defp merge_bid(%Auction{} = auction, %Bid{bidder: bidder} = bid) do
    case Enum.split_with(auction.bids, &(&1.bidder == bidder)) do
      {[], _others} ->
        Auction.put_bid(auction, bid)

      {[existing], others} ->
        merged = %{
          bid
          | max_amount: dec_max(ceiling(existing), ceiling(bid)),
            placed_at: earliest(existing.placed_at, bid.placed_at)
        }

        %{auction | bids: others ++ [merged]}
    end
  end

  # A bidder's own action must never lower their visible amount. After recompute,
  # floor each bidder at the visible amount they held before this bid (first-time
  # bidders have no prior amount). With merge_bid/2 this means a leader raising
  # their own max neither pumps nor drops their price — only a competing bidder
  # can move it.
  defp ratchet(%Auction{bids: bids} = auction, prior_visible) do
    bids =
      Enum.map(bids, fn %Bid{bidder: bidder, amount: amount} = b ->
        case Map.get(prior_visible, bidder) do
          nil -> b
          prev -> %{b | amount: dec_max(amount, prev)}
        end
      end)

    %{auction | bids: bids}
  end

  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
```

(`ceiling/1` and `dec_max/2` already exist in this module and are reused.)

- [ ] **Step 5: Run the English tests — new pass, existing stay green**

Run: `cd ~/apps/gavel && mix test test/gavel/types/english_test.exs -v`
Expected: ALL pass — the four new tests plus the existing ones, including
"a lone proxy bidder leads at the starting amount", "the higher max wins, paying
one increment above the runner-up's max", "a proxy never exceeds its own max",
"a higher bid is accepted and emits outbid", and the ranking property.

- [ ] **Step 6: Full suite + lint**

Run: `cd ~/apps/gavel && mix test && mix format --check-formatted && mix credo --strict`
Expected: all tests PASS; format clean (run `mix format` on `english.ex` if it
flags, then re-check); credo clean.

- [ ] **Step 7: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/types/english.ex test/gavel/types/english_test.exs
git -c user.email="antonis@pishias.com" -c user.name="Antonis" \
  commit -m "fix(english): a bidder can no longer pump their own visible price"
```

---

## Task 2: gavelui propagation test (live_gavel)

**Files:**
- Test: `~/apps/live_gavel/test/live_gavel/showcase_test.exs` (existing `setup` provides `%{id: id}` + `on_exit` `Showcase.stop`)

- [ ] **Step 1: Add the end-to-end no-pump test**

Append to `test/live_gavel/showcase_test.exs`, inside the module before the final `end`. The "basic" English preset is `min_increment: 10`, `closes_at: soon(90)`, no `start_price` (defaults 0):

```elixir
test "a bidder setting a higher max after a bid does not pump their own price", %{id: id} do
  {:ok, _} = Showcase.start("english", id: id, preset_id: "basic")

  {:ok, vm1} = Showcase.bid(id, "english", "alice", Decimal.new("150"))
  assert Decimal.equal?(vm1.current_price, Decimal.new("150"))
  assert [%{bidder: "alice"}] = vm1.leaderboard

  {:ok, vm2} = Showcase.set_max(id, "alice", Decimal.new("300"))
  assert Decimal.equal?(vm2.current_price, Decimal.new("150"))
  assert [%{bidder: "alice"}] = vm2.leaderboard
end
```

- [ ] **Step 2: Run the test**

Run: `cd ~/apps/live_gavel && mix test test/live_gavel/showcase_test.exs -v`
Expected: PASS. (Before the Task 1 fix this would FAIL: `set_max` would pump
`current_price` from 150 to 160 and produce a duplicate `alice` leaderboard row.)

IMPORTANT — if it fails, do NOT weaken the assertions. Confirm Task 1 is
committed in `~/apps/gavel` (the path dep) and that the running test compiled
against it; report findings.

- [ ] **Step 3: Broader unit suite + format**

Run: `cd ~/apps/live_gavel && mix test --exclude feature && mix format --check-formatted`
Expected: all PASS; format clean. (No `mix credo` config exists here — skip it;
do not add config.)

- [ ] **Step 4: Commit**

```bash
cd ~/apps/live_gavel
git add test/live_gavel/showcase_test.exs
git -c user.email="antonis@pishias.com" -c user.name="Antonis" \
  commit -m "test(showcase): bidder cannot pump their own price (set max after bid)"
```

---

## Task 3: Final verification across both repos

**Files:** none (verification only)

- [ ] **Step 1: gavel full suite + lint**

Run: `cd ~/apps/gavel && mix test && mix format --check-formatted && mix credo --strict`
Expected: all PASS / clean.

- [ ] **Step 2: live_gavel full unit suite + format**

Run: `cd ~/apps/live_gavel && mix test --exclude feature && mix format --check-formatted`
Expected: all PASS / clean.

- [ ] **Step 3: Confirm both working trees are committed**

Run: `cd ~/apps/gavel && git status --short && cd ~/apps/live_gavel && git status --short`
Expected: no English-related changes left uncommitted. (gavel is on `main` and
live_gavel on `master`, so the work already lands on each repo's integration
branch — no cross-branch merge needed. Pushing is a separate, explicit step the
controller will confirm with the user.)

---

## Self-Review Notes

- **Spec coverage:** merge-per-bidder → Task 1 Step 4 (`merge_bid/2`); ratchet → Task 1 Step 4 (`ratchet/2`); `place_bid` wiring + prior_visible capture → Task 1 Step 3; no-pump on leader re-bid & set-max → Task 1 Steps 1/5 + Task 2; rival still advances → Task 1 test 3; one entry per bidder / leaderboard dedup → Task 1 test 4 + Task 2 leaderboard assertion; existing behavior preserved → Task 1 Step 5/6.
- **Type consistency:** `merge_bid/2`, `ratchet/2`, `earliest/2` reuse the module's existing `ceiling/1` and `dec_max/2`; `prior_visible` is a `%{bidder => Decimal}` map produced in `place_bid/3` and consumed by `ratchet/2`. The merged standing bid stores the combined ceiling in `max_amount` (asserted in Task 1 test 2).
- **Scope:** single subsystem (English visible-price). One plan. `Auction.put_bid/2` and other formats untouched.
