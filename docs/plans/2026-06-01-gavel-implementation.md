# Gavel Auction Library — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Gavel`, an Elixir library that runs six auction formats (English, Dutch, Vickrey, sealed first-price, reverse, Japanese) via a pure functional core plus an opt-in OTP runtime.

**Architecture:** A dependency-light **pure core** (`Gavel.Auction`/`Gavel.Bid` structs + a `Gavel.Type` behaviour implemented once per format; every function takes an explicit `now` so it is deterministic and property-testable) sits underneath an **OTP runtime** (`Gavel.Server` GenServer per auction, `DynamicSupervisor`, `Registry`, a pluggable `Gavel.Store` with ETS + DETS adapters, optional Phoenix.PubSub events).

**Tech Stack:** Elixir 1.19 / OTP 27, `decimal` for money, `phoenix_pubsub` (optional in effect), `stream_data` for property tests, `ex_doc` + `credo` + `dialyxir` + `excoveralls` for tooling.

**Reference:** `docs/design.md` in this repo is the approved spec.

---

## Conventions used in every task

- Money is always `Decimal`. Compare with `Decimal.compare/2` (`:lt | :eq | :gt`) — **never** `==`/`>`.
- A "bidder" is any opaque term supplied by the caller; the library never interprets it.
- Core functions never call `DateTime.utc_now/0`; callers pass `now`. Tests pass a fixed `~U[...]`.
- Core returns `{:ok, auction, events}` / `{:error, reason}`; it never broadcasts. Events are `{name, payload}` tuples.
- TDD throughout: write the failing test, watch it fail, implement minimally, watch it pass, commit.
- Run all test commands from `~/apps/gavel`.

## File structure (created across the tasks below)

```
lib/gavel.ex                       # public API facade (runtime)
lib/gavel/application.ex           # supervision tree (already scaffolded; extended in Task 11)
lib/gavel/bid.ex                   # Gavel.Bid struct + constructor
lib/gavel/auction.ex               # Gavel.Auction struct, lifecycle, dump/load
lib/gavel/type.ex                  # Gavel.Type behaviour
lib/gavel/types/helpers.ex         # shared ranking / increment / reserve helpers
lib/gavel/types/english.ex         # open ascending + min increment + proxy/max
lib/gavel/types/sealed.ex          # shared sealed pipeline used by the 3 sealed types
lib/gavel/types/vickrey.ex         # sealed, highest wins, pays 2nd price
lib/gavel/types/sealed_first_price.ex  # sealed, highest wins, pays own bid
lib/gavel/types/reverse.ex         # sealed procurement, lowest wins, pays own bid
lib/gavel/types/dutch.ex           # descending clock, first accept wins
lib/gavel/types/japanese.ex        # ascending clock, last bidder standing
lib/gavel/store.ex                 # persistence behaviour
lib/gavel/store/ets.ex             # default ephemeral adapter
lib/gavel/store/dets.ex            # file-backed adapter
lib/gavel/server.ex                # GenServer per auction (timers, persistence, events)

test/support/generators.ex         # StreamData generators (Decimal amounts, bid lists)
test/gavel/bid_test.exs
test/gavel/auction_test.exs
test/gavel/types/english_test.exs
test/gavel/types/sealed_test.exs   # covers vickrey / sealed_first_price / reverse
test/gavel/types/dutch_test.exs
test/gavel/types/japanese_test.exs
test/gavel/store/ets_test.exs
test/gavel/store/dets_test.exs
test/gavel/server_test.exs
test/gavel_test.exs                # public-API integration
```

---

## Task 0: Project setup — dependencies and tooling

**Files:**
- Modify: `mix.exs`
- Modify: `test/test_helper.exs`
- Create: `.credo.exs`
- Create: `test/support/generators.ex`
- Modify: `.formatter.exs`

- [ ] **Step 1: Add dependencies and project metadata to `mix.exs`**

Replace the `project/0` and `deps/0` functions in `mix.exs` with:

```elixir
  def project do
    [
      app: :gavel,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test, "coveralls.html": :test],
      dialyzer: [plt_add_apps: [:ex_unit]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:decimal, "~> 2.0"},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
```

- [ ] **Step 2: Fetch deps**

Run: `cd ~/apps/gavel && mix deps.get`
Expected: deps resolve and download; ends with `* ... (Hex package)` lines and no error.

- [ ] **Step 3: Enable property-test imports in the test helper**

Replace `test/test_helper.exs` with:

```elixir
ExUnit.start()
```

(StreamData is imported per-test-file via `use ExUnitProperties`; no global setup needed.)

- [ ] **Step 4: Add a minimal Credo config**

Create `.credo.exs`:

```elixir
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: []},
      strict: true,
      checks: %{disabled: [{Credo.Check.Readability.ModuleDoc, []}]}
    }
  ]
}
```

- [ ] **Step 5: Add the StreamData generators support module**

Create `test/support/generators.ex`:

```elixir
defmodule Gavel.Generators do
  @moduledoc "StreamData generators for auction property tests."
  import StreamData

  @doc "A positive Decimal amount with up to 2 decimal places, 0.01..99999.99."
  def amount do
    map(integer(1..9_999_999), fn cents ->
      Decimal.div(Decimal.new(cents), Decimal.new(100))
    end)
  end

  @doc "A bidder id (small positive integer keeps collisions likely for tie tests)."
  def bidder, do: integer(1..50)

  @doc "A list of {bidder, amount} pairs, 1..10 entries."
  def bid_pairs do
    list_of(tuple({bidder(), amount()}), min_length: 1, max_length: 10)
  end
end
```

- [ ] **Step 6: Verify the project still compiles and the scaffold test runs**

Run: `cd ~/apps/gavel && mix test`
Expected: PASS (the generated `test/gavel_test.exs` `doctest` placeholder). Warnings are OK.

- [ ] **Step 7: Commit**

```bash
cd ~/apps/gavel
git add -A
git commit -m "chore: add deps (decimal, stream_data, tooling) and test generators"
```

---

## Task 1: `Gavel.Bid` struct

**Files:**
- Create: `lib/gavel/bid.ex`
- Test: `test/gavel/bid_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/gavel/bid_test.exs`:

```elixir
defmodule Gavel.BidTest do
  use ExUnit.Case, async: true
  alias Gavel.Bid

  @now ~U[2026-06-01 12:00:00Z]

  test "new/1 builds a bid with a Decimal amount and defaults" do
    bid = Bid.new(bidder: 7, amount: Decimal.new("10.50"), placed_at: @now)

    assert bid.bidder == 7
    assert Decimal.equal?(bid.amount, Decimal.new("10.50"))
    assert bid.max_amount == nil
    assert bid.placed_at == @now
  end

  test "new/1 coerces a string or integer amount into Decimal" do
    assert Decimal.equal?(Bid.new(bidder: 1, amount: "3", placed_at: @now).amount, Decimal.new(3))
    assert Decimal.equal?(Bid.new(bidder: 1, amount: 3, placed_at: @now).amount, Decimal.new(3))
  end

  test "new/1 stores an optional max_amount as Decimal" do
    bid = Bid.new(bidder: 1, amount: "5", max_amount: "20", placed_at: @now)
    assert Decimal.equal?(bid.max_amount, Decimal.new(20))
  end
end
```

- [ ] **Step 2: Run it to confirm failure**

Run: `cd ~/apps/gavel && mix test test/gavel/bid_test.exs`
Expected: FAIL — `Gavel.Bid.new/1 is undefined`.

- [ ] **Step 3: Implement `Gavel.Bid`**

Create `lib/gavel/bid.ex`:

```elixir
defmodule Gavel.Bid do
  @moduledoc "A single bid in an auction."

  @enforce_keys [:bidder, :amount, :placed_at]
  defstruct [:bidder, :amount, :max_amount, :placed_at]

  @type t :: %__MODULE__{
          bidder: term(),
          amount: Decimal.t(),
          max_amount: Decimal.t() | nil,
          placed_at: DateTime.t()
        }

  @doc "Builds a bid, coercing `amount`/`max_amount` to `Decimal`."
  def new(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      bidder: Map.fetch!(attrs, :bidder),
      amount: to_decimal(Map.fetch!(attrs, :amount)),
      max_amount: attrs |> Map.get(:max_amount) |> to_decimal_or_nil(),
      placed_at: Map.fetch!(attrs, :placed_at)
    }
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp to_decimal_or_nil(nil), do: nil
  defp to_decimal_or_nil(other), do: to_decimal(other)
end
```

- [ ] **Step 4: Run it to confirm pass**

Run: `cd ~/apps/gavel && mix test test/gavel/bid_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/bid.ex test/gavel/bid_test.exs
git commit -m "feat: add Gavel.Bid struct with Decimal coercion"
```

---

## Task 2: `Gavel.Type` behaviour

**Files:**
- Create: `lib/gavel/type.ex`

This task defines the contract every format implements. No test of its own (a behaviour has no runtime behavior); it is exercised by every type test that follows.

- [ ] **Step 1: Implement the behaviour**

Create `lib/gavel/type.ex`:

```elixir
defmodule Gavel.Type do
  @moduledoc """
  The behaviour every auction format implements.

  `kind/0` tells the lifecycle how to initialise an auction:

    * `:open`   — bids are public; no phase (English)
    * `:sealed` — bids hidden until close; uses `:phase` (Vickrey, sealed first-price, reverse)
    * `:clock`  — price moves on a timer (Dutch, Japanese)

  Functions receive and return `Gavel.Auction` structs and never raise on bad
  bids — they return `{:error, reason}`. `now` is always supplied by the caller.
  """

  alias Gavel.{Auction, Bid}

  @type events :: [{atom(), map()}]
  @type result :: {:sold, bidder :: term(), price :: Decimal.t()} | :no_sale

  @callback kind() :: :open | :sealed | :clock
  @callback validate_config(config :: map()) :: :ok | {:error, term()}
  @callback place_bid(Auction.t(), Bid.t(), now :: DateTime.t()) ::
              {:ok, Auction.t(), events()} | {:error, term()}
  @callback resolve(Auction.t(), now :: DateTime.t()) :: {:ok, Auction.t(), events()}

  @doc "Advance a clock-driven auction. Only `:clock` types implement this."
  @callback tick(Auction.t(), now :: DateTime.t()) :: {:ok, Auction.t(), events()}

  @doc "Withdraw a bidder. Only Japanese implements this."
  @callback drop_out(Auction.t(), bidder :: term(), now :: DateTime.t()) ::
              {:ok, Auction.t(), events()} | {:error, term()}

  @optional_callbacks tick: 2, drop_out: 3
end
```

- [ ] **Step 2: Confirm it compiles**

Run: `cd ~/apps/gavel && mix compile`
Expected: compiles, no errors.

- [ ] **Step 3: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/type.ex
git commit -m "feat: add Gavel.Type behaviour"
```

---

## Task 3: `Gavel.Auction` struct and lifecycle

**Files:**
- Create: `lib/gavel/auction.ex`
- Test: `test/gavel/auction_test.exs`

We need a real type to exercise `new/1`, so this task includes a tiny inline stub type in the test.

- [ ] **Step 1: Write the failing test**

Create `test/gavel/auction_test.exs`:

```elixir
defmodule Gavel.AuctionTest do
  use ExUnit.Case, async: true
  alias Gavel.{Auction, Bid}

  # Minimal stub format for lifecycle tests.
  defmodule StubType do
    @behaviour Gavel.Type
    @impl true
    def kind, do: :open
    @impl true
    def validate_config(%{bad: true}), do: {:error, :bad_config}
    def validate_config(_), do: :ok
    @impl true
    def place_bid(auction, bid, _now), do: {:ok, Auction.put_bid(auction, bid), [{:bid_placed, %{bid: bid}}]}
    @impl true
    def resolve(auction, _now), do: {:ok, %{auction | result: :no_sale}, [{:closed, %{result: :no_sale}}]}
  end

  @now ~U[2026-06-01 12:00:00Z]

  test "new/1 builds a pending auction" do
    assert {:ok, auction} = Auction.new(%{id: "a1", type: StubType})
    assert auction.id == "a1"
    assert auction.status == :pending
    assert auction.bids == []
  end

  test "new/1 surfaces config validation errors" do
    assert {:error, :bad_config} = Auction.new(%{id: "a1", type: StubType, bad: true})
  end

  test "open/2 marks the auction open and records timestamps" do
    {:ok, auction} = Auction.new(%{id: "a1", type: StubType, closes_at: ~U[2026-06-01 13:00:00Z]})
    auction = Auction.open(auction, @now)
    assert auction.status == :open
    assert auction.opened_at == @now
    assert auction.closes_at == ~U[2026-06-01 13:00:00Z]
  end

  test "put_bid/2 appends a bid" do
    {:ok, auction} = Auction.new(%{id: "a1", type: StubType})
    bid = Bid.new(bidder: 1, amount: "5", placed_at: @now)
    auction = Auction.put_bid(auction, bid)
    assert auction.bids == [bid]
  end

  test "dump/1 then load/1 round-trips a struct with bids" do
    {:ok, auction} = Auction.new(%{id: "a1", type: StubType})
    auction = auction |> Auction.open(@now) |> Auction.put_bid(Bid.new(bidder: 1, amount: "5", placed_at: @now))

    reloaded = auction |> Auction.dump() |> Auction.load()

    assert reloaded.id == auction.id
    assert reloaded.status == :open
    assert [%Bid{bidder: 1}] = reloaded.bids
    assert Decimal.equal?(hd(reloaded.bids).amount, Decimal.new(5))
  end
end
```

- [ ] **Step 2: Run it to confirm failure**

Run: `cd ~/apps/gavel && mix test test/gavel/auction_test.exs`
Expected: FAIL — `Gavel.Auction.new/1 is undefined`.

- [ ] **Step 3: Implement `Gavel.Auction`**

Create `lib/gavel/auction.ex`:

```elixir
defmodule Gavel.Auction do
  @moduledoc "The auction state struct and its pure lifecycle functions."

  alias Gavel.Bid

  @enforce_keys [:type, :status, :config]
  defstruct id: nil,
            type: nil,
            status: :pending,
            phase: nil,
            config: %{},
            bids: [],
            opened_at: nil,
            closes_at: nil,
            result: nil,
            extra: %{}

  @type status :: :pending | :open | :closed
  @type result :: {:sold, term(), Decimal.t()} | :no_sale | nil
  @type t :: %__MODULE__{
          id: term(),
          type: module(),
          status: status(),
          phase: atom() | nil,
          config: map(),
          bids: [Bid.t()],
          opened_at: DateTime.t() | nil,
          closes_at: DateTime.t() | nil,
          result: result(),
          extra: map()
        }

  @doc "Builds a `:pending` auction from a config map. Returns `{:error, reason}` if the type rejects the config."
  def new(config) when is_map(config) do
    type = Map.fetch!(config, :type)

    case type.validate_config(config) do
      :ok ->
        {:ok,
         %__MODULE__{
           id: Map.get(config, :id),
           type: type,
           status: :pending,
           phase: initial_phase(type),
           config: config,
           bids: [],
           closes_at: Map.get(config, :closes_at),
           extra: %{}
         }}

      {:error, _reason} = err ->
        err
    end
  end

  defp initial_phase(type) do
    case type.kind() do
      :sealed -> :bidding
      _ -> nil
    end
  end

  @doc "Transitions a pending auction to `:open`."
  def open(%__MODULE__{} = auction, %DateTime{} = now) do
    %{auction | status: :open, opened_at: now}
  end

  @doc "Appends a bid (chronological order)."
  def put_bid(%__MODULE__{} = auction, %Bid{} = bid) do
    %{auction | bids: auction.bids ++ [bid]}
  end

  @doc "Whether the auction is still accepting actions."
  def open?(%__MODULE__{status: :open}), do: true
  def open?(%__MODULE__{}), do: false

  @doc "Serialises to a plain map of JSON-friendly terms (Decimals -> strings)."
  def dump(%__MODULE__{} = a) do
    %{
      id: a.id,
      type: Atom.to_string(a.type),
      status: a.status,
      phase: a.phase,
      config: dump_config(a.config),
      bids: Enum.map(a.bids, &dump_bid/1),
      opened_at: dump_dt(a.opened_at),
      closes_at: dump_dt(a.closes_at),
      result: dump_result(a.result),
      extra: dump_extra(a.extra)
    }
  end

  @doc "Rebuilds an `%Auction{}` from `dump/1` output."
  def load(%{} = m) do
    %__MODULE__{
      id: m.id,
      type: String.to_existing_atom(m.type),
      status: m.status,
      phase: m.phase,
      config: load_config(m.config),
      bids: Enum.map(m.bids, &load_bid/1),
      opened_at: load_dt(m.opened_at),
      closes_at: load_dt(m.closes_at),
      result: load_result(m.result),
      extra: load_extra(m.extra)
    }
  end

  # --- dump/load helpers: every Decimal becomes a string and back ---

  defp dump_bid(%Bid{} = b) do
    %{bidder: b.bidder, amount: dec(b.amount), max_amount: dec(b.max_amount), placed_at: dump_dt(b.placed_at)}
  end

  defp load_bid(%{} = m) do
    Bid.new(bidder: m.bidder, amount: m.amount, max_amount: m.max_amount, placed_at: load_dt(m.placed_at))
  end

  defp dump_config(config), do: Map.new(config, fn {k, v} -> {k, dump_val(v)} end)
  defp load_config(config), do: Map.new(config, fn {k, v} -> {k, load_val(k, v)} end)

  defp dump_extra(extra), do: Map.new(extra, fn {k, v} -> {k, dump_val(v)} end)
  defp load_extra(extra), do: Map.new(extra, fn {k, v} -> {k, load_val(k, v)} end)

  # config/extra values may be Decimals, atoms, DateTimes, MapSets, plain terms.
  defp dump_val(%Decimal{} = d), do: {:dec, dec(d)}
  defp dump_val(%DateTime{} = dt), do: {:dt, dump_dt(dt)}
  defp dump_val(%MapSet{} = s), do: {:set, MapSet.to_list(s)}
  defp dump_val(other), do: other

  defp load_val(:type, v), do: String.to_existing_atom(v)
  defp load_val(_k, {:dec, s}), do: Decimal.new(s)
  defp load_val(_k, {:dt, s}), do: load_dt(s)
  defp load_val(_k, {:set, list}), do: MapSet.new(list)
  defp load_val(_k, other), do: other

  defp dump_result({:sold, bidder, price}), do: {:sold, bidder, dec(price)}
  defp dump_result(other), do: other
  defp load_result({:sold, bidder, price}), do: {:sold, bidder, Decimal.new(price)}
  defp load_result(other), do: other

  defp dec(nil), do: nil
  defp dec(%Decimal{} = d), do: Decimal.to_string(d)

  defp dump_dt(nil), do: nil
  defp dump_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp load_dt(nil), do: nil
  defp load_dt(s) when is_binary(s), do: elem(DateTime.from_iso8601(s), 1)
  defp load_dt(%DateTime{} = dt), do: dt
end
```

> Note: `dump_config` wraps a config's `:type` atom via `dump_val`'s catch-all (atoms pass through), and `load_config` restores it via the `:type` clause. This is why `load_val(:type, v)` exists.

- [ ] **Step 4: Run it to confirm pass**

Run: `cd ~/apps/gavel && mix test test/gavel/auction_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/auction.ex test/gavel/auction_test.exs
git commit -m "feat: add Gavel.Auction struct, lifecycle, and dump/load"
```

---

## Task 4: Shared type helpers (ranking, increment, reserve, anti-snipe)

**Files:**
- Create: `lib/gavel/types/helpers.ex`

Exercised by the English/sealed tests; no standalone test file. Provides the DRY primitives every format reuses.

- [ ] **Step 1: Implement helpers**

Create `lib/gavel/types/helpers.ex`:

```elixir
defmodule Gavel.Types.Helpers do
  @moduledoc "Pure helpers shared across auction formats."

  alias Gavel.{Auction, Bid}

  @doc "Bids ranked highest amount first; ties broken by earliest `placed_at`."
  def ranked_desc(bids) do
    Enum.sort(bids, fn a, b ->
      case Decimal.compare(a.amount, b.amount) do
        :gt -> true
        :lt -> false
        :eq -> DateTime.compare(a.placed_at, b.placed_at) != :gt
      end
    end)
  end

  @doc "Bids ranked lowest amount first; ties broken by earliest `placed_at`. (reverse auctions)"
  def ranked_asc(bids) do
    Enum.sort(bids, fn a, b ->
      case Decimal.compare(a.amount, b.amount) do
        :lt -> true
        :gt -> false
        :eq -> DateTime.compare(a.placed_at, b.placed_at) != :gt
      end
    end)
  end

  @doc "The current highest bid, or nil."
  def highest(bids), do: bids |> ranked_desc() |> List.first()

  @doc "`true` when `amount` beats `floor` by at least `min_increment` (nil increment ⇒ any strictly-higher amount)."
  def meets_increment?(amount, nil, nil), do: Decimal.compare(amount, Decimal.new(0)) == :gt
  def meets_increment?(amount, nil, _min), do: Decimal.compare(amount, Decimal.new(0)) == :gt

  def meets_increment?(amount, %Decimal{} = current, nil) do
    Decimal.compare(amount, current) == :gt
  end

  def meets_increment?(amount, %Decimal{} = current, %Decimal{} = min) do
    Decimal.compare(amount, Decimal.add(current, min)) != :lt
  end

  @doc "Reserve from config, or nil."
  def reserve(%Auction{config: config}), do: Map.get(config, :reserve_price)

  @doc "`true` when a winning amount clears the reserve (no reserve ⇒ always true)."
  def clears_reserve?(_amount, nil), do: true
  def clears_reserve?(%Decimal{} = amount, %Decimal{} = reserve), do: Decimal.compare(amount, reserve) != :lt

  @doc """
  Applies anti-snipe: if `now` is within the config window of `closes_at`, push
  `closes_at` out by the configured seconds and emit an `:extended` event.
  Returns `{auction, events}`.
  """
  def maybe_extend(%Auction{config: config, closes_at: closes_at} = auction, %DateTime{} = now)
      when not is_nil(closes_at) do
    case Map.get(config, :anti_snipe) do
      %{window: window_s, extend_by: extend_s} ->
        remaining = DateTime.diff(closes_at, now, :second)

        if remaining >= 0 and remaining <= window_s do
          new_closes = DateTime.add(closes_at, extend_s, :second)
          {%{auction | closes_at: new_closes}, [{:extended, %{closes_at: new_closes}}]}
        else
          {auction, []}
        end

      _ ->
        {auction, []}
    end
  end

  def maybe_extend(auction, _now), do: {auction, []}

  @doc "Standard guard: reject any action on a non-open auction."
  def ensure_open(%Auction{status: :open}), do: :ok
  def ensure_open(%Auction{}), do: {:error, :auction_closed}
end
```

- [ ] **Step 2: Confirm compile**

Run: `cd ~/apps/gavel && mix compile`
Expected: compiles cleanly.

- [ ] **Step 3: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/types/helpers.ex
git commit -m "feat: add shared auction type helpers (ranking, increment, reserve, anti-snipe)"
```

---

## Task 5: English auction — open ascending + min increment + reserve

**Files:**
- Create: `lib/gavel/types/english.ex`
- Test: `test/gavel/types/english_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/gavel/types/english_test.exs`:

```elixir
defmodule Gavel.Types.EnglishTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Gavel.{Auction, Bid}
  alias Gavel.Generators

  @now ~U[2026-06-01 12:00:00Z]

  defp open_auction(config \\ %{}) do
    {:ok, a} = Auction.new(Map.merge(%{id: "e1", type: Gavel.Types.English}, config))
    Auction.open(a, @now)
  end

  defp bid(auction, bidder, amount, secs \\ 0) do
    b = Bid.new(bidder: bidder, amount: amount, placed_at: DateTime.add(@now, secs, :second))
    auction.type.place_bid(auction, b, b.placed_at)
  end

  test "first bid is accepted" do
    {:ok, a, events} = bid(open_auction(), 1, "10")
    assert [%Bid{bidder: 1}] = a.bids
    assert [{:bid_placed, _}] = events
  end

  test "a higher bid is accepted and emits outbid for the prior leader" do
    {:ok, a, _} = bid(open_auction(), 1, "10")
    {:ok, a, events} = bid(a, 2, "12", 1)
    assert [{:bid_placed, _}, {:outbid, %{bidder: 1}}] = events
    assert Decimal.equal?(Gavel.Types.Helpers.highest(a.bids).amount, Decimal.new(12))
  end

  test "a bid that does not beat the current high is rejected" do
    {:ok, a, _} = bid(open_auction(), 1, "10")
    assert {:error, :bid_too_low} = bid(a, 2, "10", 1)
  end

  test "min_increment is enforced" do
    a = open_auction(%{min_increment: Decimal.new(5)})
    {:ok, a, _} = bid(a, 1, "10")
    assert {:error, :below_min_increment} = bid(a, 2, "12", 1)
    assert {:ok, _, _} = bid(a, 2, "15", 1)
  end

  test "bids on a closed auction are rejected" do
    a = %{open_auction() | status: :closed}
    assert {:error, :auction_closed} = bid(a, 1, "10")
  end

  test "resolve sells to the highest bidder at their own bid" do
    {:ok, a, _} = bid(open_auction(), 1, "10")
    {:ok, a, _} = bid(a, 2, "20", 1)
    {:ok, a, [{:closed, _}]} = Gavel.Types.English.resolve(a, @now)
    assert {:sold, 2, price} = a.result
    assert Decimal.equal?(price, Decimal.new(20))
  end

  test "resolve below reserve yields :no_sale" do
    a = open_auction(%{reserve_price: Decimal.new(50)})
    {:ok, a, _} = bid(a, 1, "20")
    {:ok, a, _} = Gavel.Types.English.resolve(a, @now)
    assert a.result == :no_sale
  end

  property "the winner is always the highest bid; ties go to the earliest" do
    check all pairs <- Generators.bid_pairs() do
      a = open_auction()

      a =
        pairs
        |> Enum.with_index()
        |> Enum.reduce(a, fn {{bidder, amount}, i}, acc ->
          b = Bid.new(bidder: bidder, amount: amount, placed_at: DateTime.add(@now, i, :second))
          # bypass increment rules: we are testing resolve, so append directly
          Auction.put_bid(acc, b)
        end)

      {:ok, a, _} = Gavel.Types.English.resolve(a, @now)
      ranked = Gavel.Types.Helpers.ranked_desc(a.bids)
      top = hd(ranked)
      assert {:sold, top.bidder, price} = a.result
      assert Decimal.equal?(price, top.amount)
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd ~/apps/gavel && mix test test/gavel/types/english_test.exs`
Expected: FAIL — `Gavel.Types.English` undefined.

- [ ] **Step 3: Implement English**

Create `lib/gavel/types/english.ex`:

```elixir
defmodule Gavel.Types.English do
  @moduledoc "Open ascending auction: highest bid wins and pays its own bid."
  @behaviour Gavel.Type

  alias Gavel.{Auction, Bid}
  alias Gavel.Types.Helpers

  @impl true
  def kind, do: :open

  @impl true
  def validate_config(_config), do: :ok

  @impl true
  def place_bid(%Auction{} = auction, %Bid{} = bid, %DateTime{} = now) do
    with :ok <- Helpers.ensure_open(auction),
         :ok <- check_increment(auction, bid) do
      prior = Helpers.highest(auction.bids)
      {auction, extend_events} = Helpers.maybe_extend(Auction.put_bid(auction, bid), now)

      events =
        [{:bid_placed, %{bid: bid}}] ++
          outbid_event(prior, bid) ++
          extend_events

      {:ok, auction, events}
    end
  end

  @impl true
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

    {:ok, %{auction | status: :closed, result: result}, [{:closed, %{result: result}}]}
  end

  defp check_increment(auction, bid) do
    current = current_amount(auction)
    min = Map.get(auction.config, :min_increment)

    cond do
      current == nil -> :ok
      Decimal.compare(bid.amount, current) != :gt -> {:error, :bid_too_low}
      Helpers.meets_increment?(bid.amount, current, min) -> :ok
      true -> {:error, :below_min_increment}
    end
  end

  defp current_amount(auction) do
    case Helpers.highest(auction.bids) do
      nil -> nil
      %Bid{amount: amount} -> amount
    end
  end

  defp outbid_event(nil, _new), do: []
  defp outbid_event(%Bid{bidder: same}, %Bid{bidder: same}), do: []
  defp outbid_event(%Bid{bidder: prior}, _new), do: [{:outbid, %{bidder: prior}}]
end
```

- [ ] **Step 4: Run to confirm pass**

Run: `cd ~/apps/gavel && mix test test/gavel/types/english_test.exs`
Expected: PASS (7 tests + 1 property).

- [ ] **Step 5: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/types/english.ex test/gavel/types/english_test.exs
git commit -m "feat: add English auction (ascending, increment, reserve)"
```

---

## Task 6: Proxy / max bidding for English

**Files:**
- Modify: `lib/gavel/types/english.ex`
- Modify: `test/gavel/types/english_test.exs`

Proxy bidding: a bidder supplies `max_amount`. The stored *visible* amount is auto-advanced so the
highest max leads at one increment above the runner-up's max (never exceeding the leader's max). We
recompute the visible leader amount on every bid.

- [ ] **Step 1: Add failing proxy tests**

Append to `test/gavel/types/english_test.exs` (before the final `end`):

```elixir
  defp proxy(auction, bidder, max, secs \\ 0) do
    b = Bid.new(bidder: bidder, amount: max, max_amount: max, placed_at: DateTime.add(@now, secs, :second))
    auction.type.place_bid(auction, b, b.placed_at)
  end

  describe "proxy/max bidding" do
    test "a lone proxy bidder leads at the starting amount, not their max" do
      a = open_auction(%{min_increment: Decimal.new(1), start_price: Decimal.new(10)})
      {:ok, a, _} = proxy(a, 1, "100")
      leader = Gavel.Types.Helpers.highest(a.bids)
      assert leader.bidder == 1
      assert Decimal.equal?(leader.amount, Decimal.new(10))
    end

    test "the higher max wins, paying one increment above the runner-up's max" do
      a = open_auction(%{min_increment: Decimal.new(5), start_price: Decimal.new(10)})
      {:ok, a, _} = proxy(a, 1, "80")
      {:ok, a, _} = proxy(a, 2, "100", 1)
      leader = Gavel.Types.Helpers.highest(a.bids)
      assert leader.bidder == 2
      assert Decimal.equal?(leader.amount, Decimal.new(85))
    end

    test "a proxy never exceeds its own max" do
      a = open_auction(%{min_increment: Decimal.new(5), start_price: Decimal.new(10)})
      {:ok, a, _} = proxy(a, 1, "100")
      {:ok, a, _} = proxy(a, 2, "98", 1)
      leader = Gavel.Types.Helpers.highest(a.bids)
      assert leader.bidder == 1
      # one increment above 98 would be 103 > 100, so capped at the leader's max
      assert Decimal.equal?(leader.amount, Decimal.new(100))
    end
  end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd ~/apps/gavel && mix test test/gavel/types/english_test.exs`
Expected: FAIL — proxy amounts are not auto-advanced (lone bidder shows 100, not 10).

- [ ] **Step 3: Implement proxy resolution in English**

In `lib/gavel/types/english.ex`, replace `place_bid/3` and add the proxy helpers below it:

```elixir
  @impl true
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

  # A bid is admissible if its *ceiling* (max_amount or amount) can beat the
  # current leader by the increment.
  defp check_admissible(auction, bid) do
    ceiling = bid.max_amount || bid.amount
    current = current_amount(auction)
    min = Map.get(auction.config, :min_increment)

    cond do
      current == nil -> :ok
      Decimal.compare(ceiling, current) != :gt -> {:error, :bid_too_low}
      Helpers.meets_increment?(ceiling, current, min) -> :ok
      true -> {:error, :below_min_increment}
    end
  end

  # Re-derive each bidder's visible amount from the set of ceilings, so the top
  # ceiling leads at one increment over the second ceiling (capped at its own max).
  defp recompute_visible_amounts(auction) do
    min = Map.get(auction.config, :min_increment) || Decimal.new(0)
    start = Map.get(auction.config, :start_price) || Decimal.new(0)

    ranked =
      auction.bids
      |> Enum.sort(fn a, b ->
        case Decimal.compare(ceiling(a), ceiling(b)) do
          :gt -> true
          :lt -> false
          :eq -> DateTime.compare(a.placed_at, b.placed_at) != :gt
        end
      end)

    bids =
      case ranked do
        [] ->
          []

        [leader] ->
          [%{leader | amount: dec_max(start, base_amount(leader))} | []]

        [leader, runner | rest] ->
          runner_ceiling = ceiling(runner)
          target = dec_min(ceiling(leader), Decimal.add(runner_ceiling, min))
          target = dec_max(target, start)
          [%{leader | amount: target}, %{runner | amount: dec_max(start, base_amount(runner))} | rest]
      end

    %{auction | bids: bids}
  end

  defp ceiling(%Bid{max_amount: nil, amount: a}), do: a
  defp ceiling(%Bid{max_amount: m}), do: m
  defp base_amount(%Bid{amount: a}), do: a
  defp dec_min(a, b), do: if(Decimal.compare(a, b) == :lt, do: a, else: b)
  defp dec_max(a, b), do: if(Decimal.compare(a, b) == :gt, do: a, else: b)
```

Also delete the now-unused `check_increment/2` (replaced by `check_admissible/2`); keep `current_amount/1`, `outbid_event/2`, and update the second `outbid_event` clause is unchanged.

> Note: `recompute_visible_amounts/1` only re-derives the top two visible amounts; deeper bidders keep their submitted base amount, which is sufficient because only the leader's price is ever paid. This keeps the increment-war resolution O(n log n) and easy to reason about.

- [ ] **Step 4: Run to confirm pass**

Run: `cd ~/apps/gavel && mix test test/gavel/types/english_test.exs`
Expected: PASS (all prior tests + 3 proxy tests + property).

- [ ] **Step 5: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/types/english.ex test/gavel/types/english_test.exs
git commit -m "feat: add proxy/max bidding to English auctions"
```

---

## Task 7: Sealed auctions — Vickrey, sealed first-price, reverse

**Files:**
- Create: `lib/gavel/types/sealed.ex`
- Create: `lib/gavel/types/vickrey.ex`
- Create: `lib/gavel/types/sealed_first_price.ex`
- Create: `lib/gavel/types/reverse.ex`
- Test: `test/gavel/types/sealed_test.exs`

All three share one pipeline: accept hidden bids while `:open`/`phase: :bidding`; at `resolve`,
pick the winner and price by a per-type strategy. `Gavel.Types.Sealed` holds the shared logic; the
three modules are thin wrappers passing a `pricing` strategy.

- [ ] **Step 1: Write the failing tests**

Create `test/gavel/types/sealed_test.exs`:

```elixir
defmodule Gavel.Types.SealedTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Gavel.{Auction, Bid}
  alias Gavel.Generators

  @now ~U[2026-06-01 12:00:00Z]

  defp sealed(type, config \\ %{}) do
    {:ok, a} = Auction.new(Map.merge(%{id: "s1", type: type}, config))
    Auction.open(a, @now)
  end

  defp bid(auction, bidder, amount, secs \\ 0) do
    b = Bid.new(bidder: bidder, amount: amount, placed_at: DateTime.add(@now, secs, :second))
    auction.type.place_bid(auction, b, b.placed_at)
  end

  describe "sealed bidding (shared)" do
    test "any number of bids are accepted while open, hidden from each other" do
      a = sealed(Gavel.Types.Vickrey)
      {:ok, a, _} = bid(a, 1, "10")
      {:ok, a, _} = bid(a, 2, "20", 1)
      assert length(a.bids) == 2
    end

    test "a second bid by the same bidder replaces the first" do
      a = sealed(Gavel.Types.Vickrey)
      {:ok, a, _} = bid(a, 1, "10")
      {:ok, a, _} = bid(a, 1, "15", 1)
      assert [%Bid{bidder: 1, amount: amt}] = a.bids
      assert Decimal.equal?(amt, Decimal.new(15))
    end
  end

  describe "Vickrey" do
    test "highest wins, pays the second-highest bid" do
      a = sealed(Gavel.Types.Vickrey)
      {:ok, a, _} = bid(a, 1, "30")
      {:ok, a, _} = bid(a, 2, "50", 1)
      {:ok, a, _} = bid(a, 3, "40", 2)
      {:ok, a, _} = Gavel.Types.Vickrey.resolve(a, @now)
      assert {:sold, 2, price} = a.result
      assert Decimal.equal?(price, Decimal.new(40))
    end

    test "below reserve ⇒ no_sale" do
      a = sealed(Gavel.Types.Vickrey, %{reserve_price: Decimal.new(100)})
      {:ok, a, _} = bid(a, 1, "30")
      {:ok, a, _} = Gavel.Types.Vickrey.resolve(a, @now)
      assert a.result == :no_sale
    end

    test "single bidder pays the reserve when set" do
      a = sealed(Gavel.Types.Vickrey, %{reserve_price: Decimal.new(25)})
      {:ok, a, _} = bid(a, 1, "40")
      {:ok, a, _} = Gavel.Types.Vickrey.resolve(a, @now)
      assert {:sold, 1, price} = a.result
      assert Decimal.equal?(price, Decimal.new(25))
    end
  end

  describe "SealedFirstPrice" do
    test "highest wins, pays their own bid" do
      a = sealed(Gavel.Types.SealedFirstPrice)
      {:ok, a, _} = bid(a, 1, "30")
      {:ok, a, _} = bid(a, 2, "50", 1)
      {:ok, a, _} = Gavel.Types.SealedFirstPrice.resolve(a, @now)
      assert {:sold, 2, price} = a.result
      assert Decimal.equal?(price, Decimal.new(50))
    end
  end

  describe "Reverse (procurement)" do
    test "lowest wins, pays their own bid" do
      a = sealed(Gavel.Types.Reverse)
      {:ok, a, _} = bid(a, 1, "30")
      {:ok, a, _} = bid(a, 2, "50", 1)
      {:ok, a, _} = bid(a, 3, "20", 2)
      {:ok, a, _} = Gavel.Types.Reverse.resolve(a, @now)
      assert {:sold, 3, price} = a.result
      assert Decimal.equal?(price, Decimal.new(20))
    end

    test "reserve is a ceiling: lowest bid above the max budget ⇒ no_sale" do
      a = sealed(Gavel.Types.Reverse, %{reserve_price: Decimal.new(10)})
      {:ok, a, _} = bid(a, 1, "30")
      {:ok, a, _} = Gavel.Types.Reverse.resolve(a, @now)
      assert a.result == :no_sale
    end
  end

  property "Vickrey winner pays exactly the second-highest distinct-bidder amount" do
    check all pairs <- Generators.bid_pairs(), length(Enum.uniq_by(pairs, &elem(&1, 0))) >= 2 do
      a = sealed(Gavel.Types.Vickrey)

      a =
        pairs
        |> Enum.with_index()
        |> Enum.reduce(a, fn {{bidder, amount}, i}, acc ->
          {:ok, acc, _} =
            acc.type.place_bid(
              acc,
              Bid.new(bidder: bidder, amount: amount, placed_at: DateTime.add(@now, i, :second)),
              DateTime.add(@now, i, :second)
            )

          acc
        end)

      {:ok, a, _} = Gavel.Types.Vickrey.resolve(a, @now)
      ranked = Gavel.Types.Helpers.ranked_desc(a.bids)
      [_winner, second | _] = ranked
      assert {:sold, _, price} = a.result
      assert Decimal.equal?(price, second.amount)
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd ~/apps/gavel && mix test test/gavel/types/sealed_test.exs`
Expected: FAIL — sealed modules undefined.

- [ ] **Step 3: Implement the shared sealed pipeline**

Create `lib/gavel/types/sealed.ex`:

```elixir
defmodule Gavel.Types.Sealed do
  @moduledoc """
  Shared logic for sealed-bid formats. A bidder's latest bid replaces any prior
  one. Winner/price selection is delegated to a `pricing` function supplied by
  each concrete type at resolve time.
  """

  alias Gavel.{Auction, Bid}
  alias Gavel.Types.Helpers

  @doc "Accept a hidden bid while open; a bidder's new bid replaces their old one."
  def place_bid(%Auction{} = auction, %Bid{} = bid, _now) do
    with :ok <- Helpers.ensure_open(auction) do
      bids = Enum.reject(auction.bids, &(&1.bidder == bid.bidder)) ++ [bid]
      {:ok, %{auction | bids: bids}, [{:bid_placed, %{bidder: bid.bidder}}]}
    end
  end

  @doc """
  Resolve using a `pricing` fun: `(ranked_bids, reserve) -> result`.
  `ranked_bids` is ordered best-first per the type's `rank` fun.
  """
  def resolve(%Auction{} = auction, rank, pricing) do
    ranked = rank.(auction.bids)
    result = pricing.(ranked, Helpers.reserve(auction))
    {:ok, %{auction | status: :closed, phase: :resolved, result: result}, [{:closed, %{result: result}}]}
  end
end
```

- [ ] **Step 4: Implement the three concrete types**

Create `lib/gavel/types/vickrey.ex`:

```elixir
defmodule Gavel.Types.Vickrey do
  @moduledoc "Sealed-bid second-price auction: highest wins, pays the second-highest bid."
  @behaviour Gavel.Type

  alias Gavel.Types.{Helpers, Sealed}

  @impl true
  def kind, do: :sealed
  @impl true
  def validate_config(_), do: :ok
  @impl true
  def place_bid(auction, bid, now), do: Sealed.place_bid(auction, bid, now)

  @impl true
  def resolve(auction, _now) do
    Sealed.resolve(auction, &Helpers.ranked_desc/1, &price/2)
  end

  defp price([], _reserve), do: :no_sale

  defp price([winner | rest], reserve) do
    if Helpers.clears_reserve?(winner.amount, reserve) do
      second = second_price(rest, reserve, winner)
      {:sold, winner.bidder, second}
    else
      :no_sale
    end
  end

  # Second price = max(second-highest bid, reserve). With no runner-up, falls back to reserve.
  defp second_price([], reserve, winner), do: reserve || winner.amount
  defp second_price([second | _], reserve, _winner) do
    case reserve do
      nil -> second.amount
      r -> if Decimal.compare(second.amount, r) == :gt, do: second.amount, else: r
    end
  end
end
```

Create `lib/gavel/types/sealed_first_price.ex`:

```elixir
defmodule Gavel.Types.SealedFirstPrice do
  @moduledoc "Sealed-bid first-price auction: highest wins, pays their own bid."
  @behaviour Gavel.Type

  alias Gavel.Types.{Helpers, Sealed}

  @impl true
  def kind, do: :sealed
  @impl true
  def validate_config(_), do: :ok
  @impl true
  def place_bid(auction, bid, now), do: Sealed.place_bid(auction, bid, now)

  @impl true
  def resolve(auction, _now), do: Sealed.resolve(auction, &Helpers.ranked_desc/1, &price/2)

  defp price([], _reserve), do: :no_sale

  defp price([winner | _], reserve) do
    if Helpers.clears_reserve?(winner.amount, reserve),
      do: {:sold, winner.bidder, winner.amount},
      else: :no_sale
  end
end
```

Create `lib/gavel/types/reverse.ex`:

```elixir
defmodule Gavel.Types.Reverse do
  @moduledoc """
  Sealed procurement auction: lowest bid wins and is paid its own bid.
  `reserve_price` acts as a ceiling (max budget); a lowest bid above it ⇒ no_sale.
  """
  @behaviour Gavel.Type

  alias Gavel.Types.{Helpers, Sealed}

  @impl true
  def kind, do: :sealed
  @impl true
  def validate_config(_), do: :ok
  @impl true
  def place_bid(auction, bid, now), do: Sealed.place_bid(auction, bid, now)

  @impl true
  def resolve(auction, _now), do: Sealed.resolve(auction, &Helpers.ranked_asc/1, &price/2)

  defp price([], _ceiling), do: :no_sale

  defp price([winner | _], ceiling) do
    if within_budget?(winner.amount, ceiling),
      do: {:sold, winner.bidder, winner.amount},
      else: :no_sale
  end

  defp within_budget?(_amount, nil), do: true
  defp within_budget?(amount, ceiling), do: Decimal.compare(amount, ceiling) != :gt
end
```

- [ ] **Step 5: Run to confirm pass**

Run: `cd ~/apps/gavel && mix test test/gavel/types/sealed_test.exs`
Expected: PASS (all sealed tests + Vickrey property).

- [ ] **Step 6: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/types/sealed.ex lib/gavel/types/vickrey.ex lib/gavel/types/sealed_first_price.ex lib/gavel/types/reverse.ex test/gavel/types/sealed_test.exs
git commit -m "feat: add sealed auctions (Vickrey, sealed first-price, reverse)"
```

---

## Task 8: Dutch auction — descending clock

**Files:**
- Create: `lib/gavel/types/dutch.ex`
- Test: `test/gavel/types/dutch_test.exs`

Config: `start_price`, `floor_price`, `decrement` (per tick), all `Decimal`. The clock starts at
`start_price` (stored in `extra.price` on open via `tick` being safe from `:pending`). `tick` lowers
the price by `decrement` to a minimum of `floor_price`. `place_bid` is an *acceptance*: the bidder
buys at the current clock price (any bid `amount` is ignored). `floor_price` doubles as the reserve.

- [ ] **Step 1: Write the failing tests**

Create `test/gavel/types/dutch_test.exs`:

```elixir
defmodule Gavel.Types.DutchTest do
  use ExUnit.Case, async: true
  alias Gavel.{Auction, Bid}

  @now ~U[2026-06-01 12:00:00Z]

  defp dutch(config \\ %{}) do
    base = %{
      id: "d1",
      type: Gavel.Types.Dutch,
      start_price: Decimal.new(100),
      floor_price: Decimal.new(50),
      decrement: Decimal.new(10)
    }

    {:ok, a} = Auction.new(Map.merge(base, config))
    Gavel.Types.Dutch.start_clock(Auction.open(a, @now))
  end

  defp accept(auction, bidder, secs \\ 0) do
    b = Bid.new(bidder: bidder, amount: 0, placed_at: DateTime.add(@now, secs, :second))
    auction.type.place_bid(auction, b, b.placed_at)
  end

  test "clock starts at start_price" do
    assert Decimal.equal?(dutch().extra.price, Decimal.new(100))
  end

  test "tick lowers the price by decrement, not below floor" do
    a = dutch()
    {:ok, a, [{:price_dropped, _}]} = Gavel.Types.Dutch.tick(a, @now)
    assert Decimal.equal?(a.extra.price, Decimal.new(90))
    a = Enum.reduce(1..10, a, fn _, acc -> {:ok, acc, _} = Gavel.Types.Dutch.tick(acc, @now); acc end)
    assert Decimal.equal?(a.extra.price, Decimal.new(50))
  end

  test "the first acceptance wins at the current clock price and closes" do
    a = dutch()
    {:ok, a, _} = Gavel.Types.Dutch.tick(a, @now)
    {:ok, a, [{:closed, _}]} = accept(a, 7)
    assert {:sold, 7, price} = a.result
    assert Decimal.equal?(price, Decimal.new(90))
    assert a.status == :closed
  end

  test "an acceptance after close is rejected" do
    a = dutch()
    {:ok, a, _} = accept(a, 7)
    assert {:error, :auction_closed} = accept(a, 8, 1)
  end

  test "resolve with no acceptance is no_sale" do
    {:ok, a, _} = Gavel.Types.Dutch.resolve(dutch(), @now)
    assert a.result == :no_sale
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd ~/apps/gavel && mix test test/gavel/types/dutch_test.exs`
Expected: FAIL — `Gavel.Types.Dutch` undefined.

- [ ] **Step 3: Implement Dutch**

Create `lib/gavel/types/dutch.ex`:

```elixir
defmodule Gavel.Types.Dutch do
  @moduledoc "Descending-clock auction: the first bidder to accept the current price wins."
  @behaviour Gavel.Type

  alias Gavel.{Auction, Bid}
  alias Gavel.Types.Helpers

  @impl true
  def kind, do: :clock

  @impl true
  def validate_config(config) do
    required = [:start_price, :floor_price, :decrement]

    cond do
      Enum.any?(required, &(not match?(%Decimal{}, Map.get(config, &1)))) ->
        {:error, :missing_clock_config}

      Decimal.compare(config.floor_price, config.start_price) == :gt ->
        {:error, :floor_above_start}

      true ->
        :ok
    end
  end

  @doc "Initialise the clock to `start_price`. Call once after `Auction.open/2`."
  def start_clock(%Auction{config: config} = auction) do
    %{auction | extra: Map.put(auction.extra, :price, config.start_price)}
  end

  @impl true
  def tick(%Auction{} = auction, _now) do
    floor = auction.config.floor_price
    next = Decimal.sub(current_price(auction), auction.config.decrement)
    next = if Decimal.compare(next, floor) == :lt, do: floor, else: next
    auction = %{auction | extra: Map.put(auction.extra, :price, next)}
    {:ok, auction, [{:price_dropped, %{price: next}}]}
  end

  @impl true
  def place_bid(%Auction{} = auction, %Bid{} = bid, _now) do
    with :ok <- Helpers.ensure_open(auction) do
      price = current_price(auction)
      result = {:sold, bid.bidder, price}
      {:ok, %{auction | status: :closed, result: result}, [{:closed, %{result: result}}]}
    end
  end

  @impl true
  def resolve(%Auction{result: nil} = auction, _now) do
    {:ok, %{auction | status: :closed, result: :no_sale}, [{:closed, %{result: :no_sale}}]}
  end

  def resolve(%Auction{} = auction, _now), do: {:ok, auction, []}

  defp current_price(%Auction{extra: %{price: p}}), do: p
  defp current_price(%Auction{config: %{start_price: p}}), do: p
end
```

- [ ] **Step 4: Run to confirm pass**

Run: `cd ~/apps/gavel && mix test test/gavel/types/dutch_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/types/dutch.ex test/gavel/types/dutch_test.exs
git commit -m "feat: add Dutch (descending-clock) auction"
```

---

## Task 9: Japanese auction — ascending clock with drop-outs

**Files:**
- Create: `lib/gavel/types/japanese.ex`
- Test: `test/gavel/types/japanese_test.exs`

Config: `start_price`, `increment`. `extra` holds `%{price, active}` where `active` is a `MapSet` of
in bidders. `place_bid` registers a bidder as active (the `amount` must be ≥ current price to join;
otherwise `:bid_too_low`). `tick` raises the price by `increment`. `drop_out` removes a bidder; when
exactly one remains, the auction closes and the survivor wins at the current clock price (the price at
which the second-to-last bidder dropped).

- [ ] **Step 1: Write the failing tests**

Create `test/gavel/types/japanese_test.exs`:

```elixir
defmodule Gavel.Types.JapaneseTest do
  use ExUnit.Case, async: true
  alias Gavel.{Auction, Bid}

  @now ~U[2026-06-01 12:00:00Z]

  defp japanese(config \\ %{}) do
    base = %{id: "j1", type: Gavel.Types.Japanese, start_price: Decimal.new(10), increment: Decimal.new(5)}
    {:ok, a} = Auction.new(Map.merge(base, config))
    Gavel.Types.Japanese.start_clock(Auction.open(a, @now))
  end

  defp join(auction, bidder, secs \\ 0) do
    price = auction.extra.price
    b = Bid.new(bidder: bidder, amount: price, placed_at: DateTime.add(@now, secs, :second))
    auction.type.place_bid(auction, b, b.placed_at)
  end

  test "bidders join the active set" do
    a = japanese()
    {:ok, a, _} = join(a, 1)
    {:ok, a, _} = join(a, 2, 1)
    assert MapSet.equal?(a.extra.active, MapSet.new([1, 2]))
  end

  test "tick raises the price" do
    a = japanese()
    {:ok, a, _} = join(a, 1)
    {:ok, a, [{:price_raised, _}]} = Gavel.Types.Japanese.tick(a, @now)
    assert Decimal.equal?(a.extra.price, Decimal.new(15))
  end

  test "last bidder standing wins at the current clock price" do
    a = japanese()
    {:ok, a, _} = join(a, 1)
    {:ok, a, _} = join(a, 2, 1)
    {:ok, a, _} = Gavel.Types.Japanese.tick(a, @now)   # price 15
    {:ok, a, _} = Gavel.Types.Japanese.tick(a, @now)   # price 20
    {:ok, a, [{:closed, _}]} = Gavel.Types.Japanese.drop_out(a, 1, @now)
    assert {:sold, 2, price} = a.result
    assert Decimal.equal?(price, Decimal.new(20))
    assert a.status == :closed
  end

  test "dropping a non-participant errors" do
    a = japanese()
    {:ok, a, _} = join(a, 1)
    assert {:error, :not_active} = Gavel.Types.Japanese.drop_out(a, 99, @now)
  end

  test "resolve with one active bidder sells to them at current price" do
    a = japanese()
    {:ok, a, _} = join(a, 1)
    {:ok, a, _} = Gavel.Types.Japanese.resolve(a, @now)
    assert {:sold, 1, price} = a.result
    assert Decimal.equal?(price, Decimal.new(10))
  end

  test "resolve with no active bidders is no_sale" do
    {:ok, a, _} = Gavel.Types.Japanese.resolve(japanese(), @now)
    assert a.result == :no_sale
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd ~/apps/gavel && mix test test/gavel/types/japanese_test.exs`
Expected: FAIL — `Gavel.Types.Japanese` undefined.

- [ ] **Step 3: Implement Japanese**

Create `lib/gavel/types/japanese.ex`:

```elixir
defmodule Gavel.Types.Japanese do
  @moduledoc "Ascending-clock auction: bidders drop out as the price rises; the last one standing wins."
  @behaviour Gavel.Type

  alias Gavel.{Auction, Bid}
  alias Gavel.Types.Helpers

  @impl true
  def kind, do: :clock

  @impl true
  def validate_config(config) do
    if match?(%Decimal{}, Map.get(config, :start_price)) and match?(%Decimal{}, Map.get(config, :increment)),
      do: :ok,
      else: {:error, :missing_clock_config}
  end

  @doc "Initialise the clock and the (empty) active set. Call once after `Auction.open/2`."
  def start_clock(%Auction{config: config} = auction) do
    %{auction | extra: %{price: config.start_price, active: MapSet.new()}}
  end

  @impl true
  def place_bid(%Auction{} = auction, %Bid{} = bid, _now) do
    with :ok <- Helpers.ensure_open(auction) do
      price = auction.extra.price

      if Decimal.compare(bid.amount, price) == :lt do
        {:error, :bid_too_low}
      else
        active = MapSet.put(auction.extra.active, bid.bidder)
        {:ok, put_active(auction, active), [{:joined, %{bidder: bid.bidder}}]}
      end
    end
  end

  @impl true
  def tick(%Auction{} = auction, _now) do
    next = Decimal.add(auction.extra.price, auction.config.increment)
    {:ok, %{auction | extra: %{auction.extra | price: next}}, [{:price_raised, %{price: next}}]}
  end

  @impl true
  def drop_out(%Auction{} = auction, bidder, _now) do
    with :ok <- Helpers.ensure_open(auction) do
      if MapSet.member?(auction.extra.active, bidder) do
        active = MapSet.delete(auction.extra.active, bidder)
        auction = put_active(auction, active)
        maybe_close(auction, active)
      else
        {:error, :not_active}
      end
    end
  end

  @impl true
  def resolve(%Auction{} = auction, _now) do
    case MapSet.to_list(auction.extra.active) do
      [winner] -> close_sold(auction, winner)
      _ -> {:ok, %{auction | status: :closed, result: :no_sale}, [{:closed, %{result: :no_sale}}]}
    end
  end

  defp maybe_close(auction, active) do
    case MapSet.to_list(active) do
      [winner] -> close_sold(auction, winner)
      _ -> {:ok, auction, [{:dropped, %{remaining: MapSet.size(active)}}]}
    end
  end

  defp close_sold(auction, winner) do
    result = {:sold, winner, auction.extra.price}
    {:ok, %{auction | status: :closed, result: result}, [{:closed, %{result: result}}]}
  end

  defp put_active(auction, active), do: %{auction | extra: %{auction.extra | active: active}}
end
```

- [ ] **Step 4: Run to confirm pass**

Run: `cd ~/apps/gavel && mix test test/gavel/types/japanese_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/types/japanese.ex test/gavel/types/japanese_test.exs
git commit -m "feat: add Japanese (ascending-clock) auction"
```

---

## Task 10: `Gavel.Store` behaviour + ETS and DETS adapters

**Files:**
- Create: `lib/gavel/store.ex`
- Create: `lib/gavel/store/ets.ex`
- Create: `lib/gavel/store/dets.ex`
- Test: `test/gavel/store/ets_test.exs`
- Test: `test/gavel/store/dets_test.exs`

- [ ] **Step 1: Write the failing ETS test**

Create `test/gavel/store/ets_test.exs`:

```elixir
defmodule Gavel.Store.ETSTest do
  use ExUnit.Case, async: false
  alias Gavel.Store.ETS

  setup do
    :ok = ETS.init([])
    on_exit(fn -> if :ets.whereis(:gavel_auctions) != :undefined, do: :ets.delete_all_objects(:gavel_auctions) end)
    :ok
  end

  test "save then load round-trips" do
    :ok = ETS.save("a1", %{id: "a1", status: :open})
    assert {:ok, %{id: "a1", status: :open}} = ETS.load("a1")
  end

  test "load of a missing id is :error" do
    assert :error = ETS.load("nope")
  end

  test "delete removes the row" do
    :ok = ETS.save("a1", %{id: "a1"})
    :ok = ETS.delete("a1")
    assert :error = ETS.load("a1")
  end

  test "all/0 lists every stored dump" do
    :ok = ETS.save("a1", %{id: "a1"})
    :ok = ETS.save("a2", %{id: "a2"})
    ids = ETS.all() |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["a1", "a2"]
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd ~/apps/gavel && mix test test/gavel/store/ets_test.exs`
Expected: FAIL — `Gavel.Store.ETS` undefined.

- [ ] **Step 3: Implement the behaviour and ETS adapter**

Create `lib/gavel/store.ex`:

```elixir
defmodule Gavel.Store do
  @moduledoc """
  Persistence behaviour for live auctions. Stores `Gavel.Auction.dump/1` output
  keyed by auction id. Built-in adapters: `Gavel.Store.ETS` (default, ephemeral)
  and `Gavel.Store.DETS` (file-backed). Consumers may implement their own (e.g.
  a Postgres-backed adapter) without `Gavel` depending on a database.
  """

  @callback init(opts :: keyword()) :: :ok
  @callback save(id :: term(), dumped :: map()) :: :ok
  @callback load(id :: term()) :: {:ok, map()} | :error
  @callback delete(id :: term()) :: :ok
  @callback all() :: [map()]
end
```

Create `lib/gavel/store/ets.ex`:

```elixir
defmodule Gavel.Store.ETS do
  @moduledoc "Ephemeral ETS-backed store. Survives process restarts, not node restarts."
  @behaviour Gavel.Store

  @table :gavel_auctions

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @impl true
  def save(id, dumped) do
    :ets.insert(@table, {id, dumped})
    :ok
  end

  @impl true
  def load(id) do
    case :ets.lookup(@table, id) do
      [{^id, dumped}] -> {:ok, dumped}
      [] -> :error
    end
  end

  @impl true
  def delete(id) do
    :ets.delete(@table, id)
    :ok
  end

  @impl true
  def all do
    :ets.tab2list(@table) |> Enum.map(fn {_id, dumped} -> dumped end)
  end
end
```

- [ ] **Step 4: Run the ETS test to confirm pass**

Run: `cd ~/apps/gavel && mix test test/gavel/store/ets_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Write the failing DETS test**

Create `test/gavel/store/dets_test.exs`:

```elixir
defmodule Gavel.Store.DETSTest do
  use ExUnit.Case, async: false
  alias Gavel.Store.DETS

  setup do
    path = Path.join(System.tmp_dir!(), "gavel_test_#{System.unique_integer([:positive])}.dets")
    :ok = DETS.init(path: path)
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "save then load round-trips" do
    :ok = DETS.save("a1", %{id: "a1", status: :open})
    assert {:ok, %{id: "a1", status: :open}} = DETS.load("a1")
  end

  test "data survives a close/reopen of the table", %{path: path} do
    :ok = DETS.save("a1", %{id: "a1"})
    :ok = DETS.close()
    :ok = DETS.init(path: path)
    assert {:ok, %{id: "a1"}} = DETS.load("a1")
  end
end
```

- [ ] **Step 6: Run to confirm failure**

Run: `cd ~/apps/gavel && mix test test/gavel/store/dets_test.exs`
Expected: FAIL — `Gavel.Store.DETS` undefined.

- [ ] **Step 7: Implement the DETS adapter**

Create `lib/gavel/store/dets.ex`:

```elixir
defmodule Gavel.Store.DETS do
  @moduledoc "File-backed DETS store. Single-node durability across node restarts."
  @behaviour Gavel.Store

  @table :gavel_auctions_dets

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path) |> to_charlist()
    {:ok, @table} = :dets.open_file(@table, file: path, type: :set)
    :ok
  end

  @doc "Close the DETS file (flushes to disk)."
  def close, do: :dets.close(@table)

  @impl true
  def save(id, dumped) do
    :ok = :dets.insert(@table, {id, dumped})
    :dets.sync(@table)
  end

  @impl true
  def load(id) do
    case :dets.lookup(@table, id) do
      [{^id, dumped}] -> {:ok, dumped}
      [] -> :error
    end
  end

  @impl true
  def delete(id), do: :dets.delete(@table, id)

  @impl true
  def all do
    :dets.foldl(fn {_id, dumped}, acc -> [dumped | acc] end, [], @table)
  end
end
```

- [ ] **Step 8: Run the DETS test to confirm pass**

Run: `cd ~/apps/gavel && mix test test/gavel/store/dets_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 9: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/store.ex lib/gavel/store/ets.ex lib/gavel/store/dets.ex test/gavel/store/
git commit -m "feat: add Gavel.Store behaviour with ETS and DETS adapters"
```

---

## Task 11: OTP runtime — Application wiring + `Gavel.Server`

**Files:**
- Modify: `lib/gavel/application.ex`
- Create: `lib/gavel/server.ex`
- Test: `test/gavel/server_test.exs`

The `Server` wraps one auction: it builds bids with the real `now`, calls the type's pure functions,
persists each transition via the configured store, broadcasts events if a PubSub is configured, and
arms timers for clock ticks and `closes_at`. On `init` it rehydrates from the store if the id exists.

- [ ] **Step 1: Wire the supervision tree**

Replace `lib/gavel/application.ex` with:

```elixir
defmodule Gavel.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    store = Application.get_env(:gavel, :store, Gavel.Store.ETS)
    store_opts = Application.get_env(:gavel, :store_opts, [])
    :ok = store.init(store_opts)

    children = [
      {Registry, keys: :unique, name: Gavel.Registry},
      {DynamicSupervisor, name: Gavel.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Gavel.Supervisor)
  end
end
```

- [ ] **Step 2: Write the failing server test**

Create `test/gavel/server_test.exs`:

```elixir
defmodule Gavel.ServerTest do
  use ExUnit.Case, async: false
  alias Gavel.{Auction, Server, Store}

  setup do
    :ok = Store.ETS.init([])
    on_exit(fn -> :ets.delete_all_objects(:gavel_auctions) end)
    :ok
  end

  defp start_english(id) do
    {:ok, auction} = Auction.new(%{id: id, type: Gavel.Types.English, min_increment: Decimal.new(1)})
    {:ok, pid} = Server.start_link(auction: Auction.open(auction, DateTime.utc_now()))
    pid
  end

  test "place_bid records a bid and get returns current state" do
    pid = start_english("srv1")
    assert {:ok, _} = Server.place_bid(pid, bidder: 1, amount: "10")
    assert {:ok, _} = Server.place_bid(pid, bidder: 2, amount: "12")
    auction = Server.get(pid)
    assert Decimal.equal?(Gavel.Types.Helpers.highest(auction.bids).amount, Decimal.new(12))
  end

  test "a rejected bid returns the error and does not mutate state" do
    pid = start_english("srv2")
    assert {:ok, _} = Server.place_bid(pid, bidder: 1, amount: "10")
    assert {:error, :below_min_increment} == Server.place_bid(pid, bidder: 2, amount: "10")
  end

  test "close resolves the auction" do
    pid = start_english("srv3")
    {:ok, _} = Server.place_bid(pid, bidder: 1, amount: "10")
    {:ok, auction} = Server.close(pid)
    assert {:sold, 1, _} = auction.result
  end

  test "state is persisted to the store after each bid" do
    pid = start_english("srv4")
    {:ok, _} = Server.place_bid(pid, bidder: 1, amount: "10")
    assert {:ok, dumped} = Store.ETS.load("srv4")
    assert [%{bidder: 1}] = dumped.bids
  end

  test "a restarted server rehydrates from the store" do
    pid = start_english("srv5")
    {:ok, _} = Server.place_bid(pid, bidder: 1, amount: "10")
    GenServer.stop(pid)

    # New server with the same id but a fresh (empty) auction: init should prefer the store.
    {:ok, fresh} = Auction.new(%{id: "srv5", type: Gavel.Types.English})
    {:ok, pid2} = Server.start_link(auction: Auction.open(fresh, DateTime.utc_now()))
    auction = Server.get(pid2)
    assert [%{bidder: 1}] = auction.bids
  end
end
```

- [ ] **Step 3: Run to confirm failure**

Run: `cd ~/apps/gavel && mix test test/gavel/server_test.exs`
Expected: FAIL — `Gavel.Server` undefined.

- [ ] **Step 4: Implement `Gavel.Server`**

Create `lib/gavel/server.ex`:

```elixir
defmodule Gavel.Server do
  @moduledoc "A GenServer owning one live auction: timers, persistence, and event broadcasts."
  use GenServer

  alias Gavel.{Auction, Bid}

  # --- Client API ---

  def start_link(opts) do
    auction = Keyword.fetch!(opts, :auction)
    GenServer.start_link(__MODULE__, auction, name: via(auction.id))
  end

  def via(id), do: {:via, Registry, {Gavel.Registry, id}}

  @doc "Place a bid. `attrs` needs `:bidder` and `:amount`; optional `:max_amount`."
  def place_bid(server, attrs), do: GenServer.call(server, {:place_bid, Map.new(attrs)})

  @doc "Set a proxy max bid (English) — convenience around place_bid with max_amount = amount = max."
  def set_max_bid(server, bidder, max),
    do: place_bid(server, bidder: bidder, amount: max, max_amount: max)

  @doc "Accept the current Dutch clock price."
  def accept(server, bidder), do: place_bid(server, bidder: bidder, amount: 0)

  @doc "Drop out of a Japanese auction."
  def drop_out(server, bidder), do: GenServer.call(server, {:drop_out, bidder})

  @doc "Fetch the current auction state."
  def get(server), do: GenServer.call(server, :get)

  @doc "Force-resolve the auction now."
  def close(server), do: GenServer.call(server, :close)

  # --- Server callbacks ---

  @impl true
  def init(auction) do
    auction = rehydrate(auction)
    auction = maybe_start_clock(auction)
    state = %{auction: auction, timers: %{}}
    {:ok, arm_timers(state)}
  end

  @impl true
  def handle_call({:place_bid, attrs}, _from, %{auction: auction} = state) do
    bid =
      Bid.new(
        bidder: Map.fetch!(attrs, :bidder),
        amount: Map.fetch!(attrs, :amount),
        max_amount: Map.get(attrs, :max_amount),
        placed_at: now()
      )

    case auction.type.place_bid(auction, bid, now()) do
      {:ok, auction, events} ->
        state = commit(state, auction, events)
        {:reply, {:ok, auction}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:drop_out, bidder}, _from, %{auction: auction} = state) do
    case auction.type.drop_out(auction, bidder, now()) do
      {:ok, auction, events} -> {:reply, {:ok, auction}, commit(state, auction, events)}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:get, _from, state), do: {:reply, state.auction, state}

  def handle_call(:close, _from, %{auction: auction} = state) do
    {:ok, auction, events} = auction.type.resolve(auction, now())
    {:reply, {:ok, auction}, commit(state, auction, events)}
  end

  @impl true
  def handle_info(:tick, %{auction: auction} = state) do
    {:ok, auction, events} = auction.type.tick(auction, now())
    state = commit(state, auction, events)
    {:noreply, schedule_tick(state)}
  end

  def handle_info(:close, %{auction: auction} = state) do
    {:ok, auction, events} = auction.type.resolve(auction, now())
    {:noreply, commit(state, auction, events)}
  end

  # --- internals ---

  defp commit(state, auction, events) do
    store().save(auction.id, Auction.dump(auction))
    Enum.each(events, &broadcast(auction.id, &1))
    %{state | auction: auction}
  end

  defp rehydrate(auction) do
    case store().load(auction.id) do
      {:ok, dumped} -> Auction.load(dumped)
      :error -> auction
    end
  end

  defp maybe_start_clock(%Auction{type: type, extra: extra} = auction) do
    cond do
      type.kind() != :clock -> auction
      map_size(extra) > 0 -> auction
      function_exported?(type, :start_clock, 1) -> type.start_clock(auction)
      true -> auction
    end
  end

  defp arm_timers(state) do
    state
    |> schedule_tick()
    |> schedule_close()
  end

  defp schedule_tick(%{auction: %Auction{type: type, status: :open} = auction} = state) do
    interval = Map.get(auction.config, :tick_interval_ms)

    if type.kind() == :clock and is_integer(interval) do
      ref = Process.send_after(self(), :tick, interval)
      put_in(state, [:timers, :tick], ref)
    else
      state
    end
  end

  defp schedule_tick(state), do: state

  defp schedule_close(%{auction: %Auction{closes_at: %DateTime{} = closes_at}} = state) do
    ms = max(DateTime.diff(closes_at, now(), :millisecond), 0)
    ref = Process.send_after(self(), :close, ms)
    put_in(state, [:timers, :close], ref)
  end

  defp schedule_close(state), do: state

  defp broadcast(id, event) do
    case Application.get_env(:gavel, :pubsub) do
      nil -> :ok
      pubsub -> Phoenix.PubSub.broadcast(pubsub, "auction:#{id}", {:gavel, id, event})
    end
  end

  defp store, do: Application.get_env(:gavel, :store, Gavel.Store.ETS)
  defp now, do: DateTime.utc_now()
end
```

> Note: `broadcast/2` references `Phoenix.PubSub` only when `:pubsub` is configured; with the default `nil` it never calls into the optional dep, so core/PubSub-less users are unaffected.

- [ ] **Step 5: Run to confirm pass**

Run: `cd ~/apps/gavel && mix test test/gavel/server_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel/application.ex lib/gavel/server.ex test/gavel/server_test.exs
git commit -m "feat: add OTP runtime (Application wiring + Gavel.Server)"
```

---

## Task 12: Public API facade `Gavel`

**Files:**
- Modify: `lib/gavel.ex`
- Test: `test/gavel_test.exs`

- [ ] **Step 1: Write the failing integration test**

Replace `test/gavel_test.exs` with:

```elixir
defmodule GavelTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> :ets.delete_all_objects(:gavel_auctions) end)
    :ok
  end

  test "an English auction runs end-to-end through the public API" do
    {:ok, _pid} =
      Gavel.start_auction(%{id: "pub1", type: Gavel.Types.English, min_increment: Decimal.new(1)})

    assert {:ok, _} = Gavel.place_bid("pub1", 1, "10")
    assert {:ok, _} = Gavel.place_bid("pub1", 2, "12")
    assert {:error, :below_min_increment} = Gavel.place_bid("pub1", 3, "12")

    {:ok, auction} = Gavel.close("pub1")
    assert {:sold, 2, price} = auction.result
    assert Decimal.equal?(price, Decimal.new(12))
  end

  test "start_auction raises on invalid config" do
    assert_raise ArgumentError, fn ->
      Gavel.start_auction(%{id: "bad", type: Gavel.Types.Dutch})
    end
  end

  test "a Dutch auction sells via accept/2" do
    {:ok, _} =
      Gavel.start_auction(%{
        id: "pub2",
        type: Gavel.Types.Dutch,
        start_price: Decimal.new(100),
        floor_price: Decimal.new(50),
        decrement: Decimal.new(10)
      })

    assert {:ok, auction} = Gavel.accept("pub2", 7)
    assert {:sold, 7, price} = auction.result
    assert Decimal.equal?(price, Decimal.new(100))
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd ~/apps/gavel && mix test test/gavel_test.exs`
Expected: FAIL — `Gavel.start_auction/1` undefined.

- [ ] **Step 3: Implement the facade**

Replace `lib/gavel.ex` with:

```elixir
defmodule Gavel do
  @moduledoc """
  Public API for running auctions.

  Start an auction with `start_auction/1`, then drive it with `place_bid/3`,
  `set_max_bid/3`, `accept/2` (Dutch), `drop_out/2` (Japanese), `get/1`, and
  `close/1`. Each auction runs in its own supervised process, keyed by `:id`.

  See `Gavel.Types.*` for the available formats and their config keys.
  """

  alias Gavel.{Auction, Server}

  @doc """
  Starts a supervised auction process. The config map must include `:id` and
  `:type` (a `Gavel.Types.*` module). Raises `ArgumentError` if the type rejects
  the config (a programmer error).
  """
  def start_auction(config) when is_map(config) do
    case Auction.new(config) do
      {:ok, auction} ->
        auction = Auction.open(auction, DateTime.utc_now())
        DynamicSupervisor.start_child(Gavel.DynamicSupervisor, {Server, auction: auction})

      {:error, reason} ->
        raise ArgumentError, "invalid auction config: #{inspect(reason)}"
    end
  end

  @doc "Places a bid. `amount` may be a Decimal, integer, or string."
  def place_bid(id, bidder, amount), do: Server.place_bid(Server.via(id), bidder: bidder, amount: amount)

  @doc "Sets a proxy max bid (English)."
  def set_max_bid(id, bidder, max), do: Server.set_max_bid(Server.via(id), bidder, max)

  @doc "Accepts the current Dutch clock price."
  def accept(id, bidder), do: Server.accept(Server.via(id), bidder)

  @doc "Drops out of a Japanese auction."
  def drop_out(id, bidder), do: Server.drop_out(Server.via(id), bidder)

  @doc "Returns the current auction state."
  def get(id), do: Server.get(Server.via(id))

  @doc "Resolves the auction immediately."
  def close(id), do: Server.close(Server.via(id))
end
```

- [ ] **Step 4: Run to confirm pass**

Run: `cd ~/apps/gavel && mix test test/gavel_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/apps/gavel
git add lib/gavel.ex test/gavel_test.exs
git commit -m "feat: add public Gavel API facade"
```

---

## Task 13: Full-suite green + lint + dialyzer + coverage

**Files:** none (verification task)

- [ ] **Step 1: Run the whole suite**

Run: `cd ~/apps/gavel && mix test`
Expected: ALL tests pass. If any property test surfaces a counterexample, fix the implementation (not the property) and re-run.

- [ ] **Step 2: Format check**

Run: `cd ~/apps/gavel && mix format && mix format --check-formatted`
Expected: clean (no diff).

- [ ] **Step 3: Credo strict**

Run: `cd ~/apps/gavel && mix credo --strict`
Expected: no issues. Fix any warnings (naming, aliasing, complexity) and re-run.

- [ ] **Step 4: Dialyzer**

Run: `cd ~/apps/gavel && mix dialyzer`
Expected: builds the PLT (first run is slow) then `done (passed successfully)`. Fix any contract/typing errors.

- [ ] **Step 5: Coverage**

Run: `cd ~/apps/gavel && mix coveralls`
Expected: a coverage summary. Aim ≥ 90% on `lib/`. Add example tests for any uncovered branch (e.g. Dutch `floor_above_start` config error).

- [ ] **Step 6: Commit any fixes**

```bash
cd ~/apps/gavel
git add -A
git commit -m "chore: format, credo, dialyzer, and coverage clean-up"
```

---

## Task 14: Docs and README

**Files:**
- Modify: `README.md`
- Modify: `mix.exs` (docs config)

- [ ] **Step 1: Add ExDoc config to `mix.exs`**

Add a `docs/0` function and reference it from `project/0` (add `docs: docs()` to the keyword list):

```elixir
  defp docs do
    [
      main: "Gavel",
      extras: ["README.md", "docs/design.md"],
      groups_for_modules: [
        Core: [Gavel.Auction, Gavel.Bid, Gavel.Type],
        Formats: [
          Gavel.Types.English,
          Gavel.Types.Dutch,
          Gavel.Types.Vickrey,
          Gavel.Types.SealedFirstPrice,
          Gavel.Types.Reverse,
          Gavel.Types.Japanese
        ],
        Runtime: [Gavel, Gavel.Server, Gavel.Store, Gavel.Store.ETS, Gavel.Store.DETS]
      ]
    ]
  end
```

- [ ] **Step 2: Write the README**

Replace `README.md` with a usage-focused overview:

```markdown
# Gavel

A multi-format auction library for Elixir: English, Dutch, Vickrey, sealed
first-price, reverse, and Japanese auctions. Built as a pure functional core
(`Gavel.Auction` + the `Gavel.Type` behaviour) with an opt-in OTP runtime
(`Gavel.Server`, a `DynamicSupervisor`, a `Registry`, and a pluggable
`Gavel.Store`).

## Install

    def deps do
      [{:gavel, "~> 0.1"}]
    end

## Quick start

    {:ok, _pid} =
      Gavel.start_auction(%{
        id: "lot-42",
        type: Gavel.Types.English,
        min_increment: Decimal.new(5),
        reserve_price: Decimal.new(100)
      })

    {:ok, _} = Gavel.place_bid("lot-42", "alice", "100")
    {:ok, _} = Gavel.place_bid("lot-42", "bob", "110")
    {:ok, auction} = Gavel.close("lot-42")
    auction.result #=> {:sold, "bob", #Decimal<110>}

## Formats

| Module | Mechanism |
|---|---|
| `Gavel.Types.English` | Open ascending; highest wins, pays own bid; supports min increment + proxy/max |
| `Gavel.Types.Dutch` | Descending clock; first to `accept/2` wins at the clock price |
| `Gavel.Types.Vickrey` | Sealed; highest wins, pays the second-highest bid |
| `Gavel.Types.SealedFirstPrice` | Sealed; highest wins, pays own bid |
| `Gavel.Types.Reverse` | Sealed procurement; lowest wins, pays own bid |
| `Gavel.Types.Japanese` | Ascending clock; last bidder standing wins via `drop_out/2` |

## Persistence

By default auctions are kept in ETS (survives a process crash, not a node
restart). Configure durability or your own backend:

    config :gavel, store: Gavel.Store.DETS, store_opts: [path: "/var/lib/gavel.dets"]

Implement `Gavel.Store` to back auctions with Postgres/Redis without Gavel
depending on your database.

## Events

Set a PubSub to receive `{:gavel, auction_id, {event, payload}}` on
`"auction:<id>"`:

    config :gavel, pubsub: MyApp.PubSub

See `docs/design.md` for the full design.
```

- [ ] **Step 3: Generate docs to verify no broken references**

Run: `cd ~/apps/gavel && mix docs`
Expected: `Docs successfully generated.` with no warnings about missing modules.

- [ ] **Step 4: Commit**

```bash
cd ~/apps/gavel
git add README.md mix.exs
git commit -m "docs: add README and ExDoc configuration"
```

---

## Self-review notes (author's check against the spec)

- **Spec §1 two-layer architecture** → Tasks 1–9 (core) + 10–12 (runtime). ✅
- **Spec §2 explicit `now`** → every `place_bid`/`tick`/`resolve`/`drop_out` takes `now`; tests inject fixed time. ✅
- **Spec §3 six formats + commit-reveal-ready phase** → English (5–6), Vickrey/SealedFirstPrice/Reverse (7, `phase: :bidding`→`:resolved`), Dutch (8), Japanese (9). The `:phase` field on sealed auctions is set by `Auction.new` and advanced in `Sealed.resolve`, leaving room for a `:revealing` phase later. ✅
- **Spec §4 features** → reserve (English/sealed tests), min increment (Task 5/6), anti-snipe `maybe_extend` (Task 4, exercised via English), proxy/max (Task 6). ✅
- **Spec §5 Decimal + opaque bidder + earliest-tie** → `Bid` coercion (Task 1), `ranked_desc/asc` tie-break (Task 4), property test (Task 5). ✅
- **Spec §6 runtime: timers, PubSub-optional, ETS-recovery + Store behaviour** → Tasks 10–12; rehydrate test (Task 11) proves recovery; `broadcast/2` no-ops without `:pubsub`. ✅
- **Spec §7 errors** → tagged tuples throughout; `start_auction` raises on bad config (Task 12 test). ✅
- **Spec §8 testing** → StreamData generators (Task 0), invariants for Vickrey-second-price, highest-wins, reserve-no-sale, increment, proxy-cap, tie-break; runtime + ETS-recovery tests; credo/dialyzer/coveralls (Task 13). ✅
- **Type-name consistency check:** `Helpers.highest/1`, `ranked_desc/1`, `ranked_asc/1`, `meets_increment?/3`, `clears_reserve?/2`, `maybe_extend/2`, `ensure_open/1`; `Auction.new/1|open/2|put_bid/2|dump/1|load/1`; `Store` callbacks `init/save/load/delete/all`; `Server` API `place_bid/set_max_bid/accept/drop_out/get/close` + `via/1` — all referenced consistently across tasks. ✅
- **Known follow-ups (out of v1 scope, noted for later):** commit-reveal `:revealing` phase; a `Store.Postgres` adapter; distributing the runtime; richer Japanese semantics (simultaneous drop-outs). These match the spec's "Open questions / future work".
```
