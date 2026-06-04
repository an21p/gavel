defmodule Gavel.Server do
  @moduledoc """
  A GenServer that owns one live auction: timers, persistence, and event broadcasts.

  Each `Gavel.Server` process is responsible for exactly one auction identified by
  its `id`. It is registered in `Gavel.Registry` via `via/1` so it can be looked
  up by id without holding a pid.

  ## Lifecycle

  1. `start_link/1` receives an `%Auction{}` struct, registers the process, and
     calls `init/1`.
  2. `init/1` rehydrates from the configured store (restoring a previously
     persisted auction if one exists), optionally starts the auction clock, then
     arms the `:tick` and `:close` timers.
  3. Player actions (`place_bid/2`, `set_max_bid/3`, `accept/2`, `drop_out/2`)
     are synchronous `GenServer.call/2`s. Each delegates to the pure type module
     (`auction.type.place_bid/3`, `.drop_out/3`) with a real `DateTime.utc_now()`
     timestamp, then calls `commit/3` on success.
  4. `commit/3` persists via the configured `Gavel.Store`, broadcasts each event
     over Phoenix.PubSub (if configured), and cancels all timers once the auction
     reaches `:closed` status — stale `:tick` and `:close` messages that arrive
     afterwards are silently dropped.

  ## Timers

  - **`:tick`** — drives Dutch/Japanese clock auctions. Armed when the auction
    type's `kind/0` returns `:clock` and `:tick_interval_ms` is set in the
    auction config. Re-armed after each tick via `schedule_tick/1`.
  - **`:close`** — armed whenever `auction.closes_at` is a `%DateTime{}`. Fires
    `auction.type.resolve/2` at the scheduled wall-clock time.

  Both timers are cancelled immediately when the auction closes, regardless of
  whether the close came from a player action, an explicit `close/1` call, or the
  `:close` timer itself.

  ## Configuration (application environment)

  | Key              | Default              | Description                                      |
  |------------------|----------------------|--------------------------------------------------|
  | `:store`         | `Gavel.Store.ETS`    | Persistence adapter module                       |
  | `:store_opts`    | `[]`                 | Options passed to `store.init/1` at boot         |
  | `:pubsub`        | `nil`                | Phoenix.PubSub server name; `nil` disables       |

  Per-auction config keys consumed by `Gavel.Server` (set in `auction.config`):

  | Key                 | Used for                                        |
  |---------------------|-------------------------------------------------|
  | `:tick_interval_ms` | Clock tick cadence in milliseconds              |
  | `:closes_at`        | Auto-close `%DateTime{}` (also on the struct)   |
  | `:anti_snipe`       | Passed through to the type for snipe handling   |

  ## PubSub events

  When `:pubsub` is configured, every event emitted by the type module is
  broadcast on the topic `"auction:<id>"` as:

  ```elixir
  {:gavel, id, {event_name, payload}}
  ```

  Consumers subscribe with `Phoenix.PubSub.subscribe(pubsub, "auction:" <> id)`.

  ## Example: DETS store + PubSub

  ```elixir
  # config/runtime.exs
  config :gavel,
    store: Gavel.Store.DETS,
    store_opts: [path: "/var/lib/myapp/auctions.dets"],
    pubsub: MyApp.PubSub

  # In a LiveView or Channel:
  Phoenix.PubSub.subscribe(MyApp.PubSub, "auction:" <> auction_id)

  # Receive clause:
  def handle_info({:gavel, _id, {:bid_placed, bid}}, socket) do
    # update UI
    {:noreply, socket}
  end
  ```
  """

  use GenServer

  alias Gavel.{Auction, Bid}

  # --- Client API ---

  @doc """
  Starts and links a `Gavel.Server` for the given auction.

  Expects `opts` to include a `:auction` key holding a `%Gavel.Auction{}` struct.
  The server registers itself under `Gavel.Registry` via `via(auction.id)`, so
  only one process per auction id may run at a time.

  Returns the standard `GenServer.start_link/3` result.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    auction = Keyword.fetch!(opts, :auction)
    GenServer.start_link(__MODULE__, auction, name: via(auction.id))
  end

  @doc """
  Returns the `{:via, Registry, ...}` name tuple for an auction id.

  Use this to address a running server by id rather than by pid:

  ```elixir
  Gavel.Server.get(Gavel.Server.via(auction_id))
  ```
  """
  @spec via(term()) :: {:via, Registry, {Gavel.Registry, term()}}
  def via(id), do: {:via, Registry, {Gavel.Registry, id}}

  @doc """
  Place a bid on the auction.

  `attrs` must include `:bidder` (any term identifying the participant) and
  `:amount` (a value coercible to `Decimal`). An optional `:max_amount` enables
  proxy/automatic bidding in English-style auctions.

  Returns `{:ok, auction}` on success or `{:error, reason}` if the type module
  rejects the bid (e.g. amount too low, auction not open, bidder not eligible).
  """
  @spec place_bid(GenServer.server(), keyword() | map()) ::
          {:ok, Gavel.Auction.t()} | {:error, atom()}
  def place_bid(server, attrs), do: GenServer.call(server, {:place_bid, Map.new(attrs)})

  @doc """
  Set a proxy max bid (English auction).

  Convenience wrapper around `place_bid/2` that sets both `:amount` and
  `:max_amount` to `max`, instructing the engine to autobid on the participant's
  behalf up to that ceiling.

  Returns `{:ok, auction}` or `{:error, reason}`.
  """
  @spec set_max_bid(GenServer.server(), term(), term()) ::
          {:ok, Gavel.Auction.t()} | {:error, atom()}
  def set_max_bid(server, bidder, max),
    do: place_bid(server, bidder: bidder, amount: max, max_amount: max)

  @doc """
  Accept the current Dutch clock price.

  Sends a bid with `amount: 0`, which the Dutch type module interprets as "I
  accept whatever the clock currently shows". Returns `{:ok, auction}` on
  success or `{:error, reason}` if the auction is not in a state that accepts
  clock-accepts (e.g. already closed).
  """
  @spec accept(GenServer.server(), term()) :: {:ok, Gavel.Auction.t()} | {:error, atom()}
  def accept(server, bidder), do: place_bid(server, bidder: bidder, amount: 0)

  @doc """
  Drop out of a Japanese auction.

  Signals that the participant is no longer willing to bid at the current price.
  The Japanese type module records the drop and may resolve the auction if only
  one participant remains.

  Returns `{:ok, auction}` or `{:error, reason}`.
  """
  @spec drop_out(GenServer.server(), term()) :: {:ok, Gavel.Auction.t()} | {:error, atom()}
  def drop_out(server, bidder), do: GenServer.call(server, {:drop_out, bidder})

  @doc """
  Fetch the current auction state.

  Returns the `%Gavel.Auction{}` struct as-is (not wrapped in `{:ok, ...}`).
  This call is always synchronous and reflects the state at the moment of the
  call.
  """
  @spec get(GenServer.server()) :: Gavel.Auction.t()
  def get(server), do: GenServer.call(server, :get)

  @doc """
  Force-resolve the auction immediately.

  Calls `auction.type.resolve/2` with the current wall-clock time, persists the
  result, and broadcasts events, regardless of whether `closes_at` has been
  reached. If the auction is already closed this is a no-op and the closed state
  is returned.

  Returns `{:ok, auction}`.
  """
  @spec close(GenServer.server()) :: {:ok, Gavel.Auction.t()}
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
        {:reply, {:ok, auction}, commit(state, auction, events)}

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

  def handle_call(:close, _from, %{auction: %{status: :closed} = auction} = state) do
    {:reply, {:ok, auction}, state}
  end

  def handle_call(:close, _from, %{auction: auction} = state) do
    {:ok, auction, events} = auction.type.resolve(auction, now())
    {:reply, {:ok, auction}, commit(state, auction, events)}
  end

  @impl true
  def handle_info(:tick, %{auction: %{status: :open} = auction} = state) do
    {:ok, auction, events} = auction.type.tick(auction, now())
    state = commit(state, auction, events)
    {:noreply, schedule_tick(state)}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info(:notice, %{auction: %{status: :open} = auction} = state) do
    delay = draw_delay(auction.config)
    {:ok, auction, events} = auction.type.on_notice(auction, delay, now())
    state = commit(state, auction, events)
    {:noreply, schedule_close(state)}
  end

  def handle_info(:notice, state), do: {:noreply, state}

  def handle_info(:close, %{auction: %{status: :closed}} = state), do: {:noreply, state}

  def handle_info(:close, %{auction: auction} = state) do
    {:ok, auction, events} = auction.type.resolve(auction, now())
    {:noreply, commit(state, auction, events)}
  end

  # --- internals ---

  defp commit(state, auction, events) do
    store().save(auction.id, Auction.dump(auction))
    Enum.each(events, &broadcast(auction.id, &1))
    state = %{state | auction: auction}

    cond do
      auction.status == :closed -> cancel_timers(state)
      extended?(events) -> reschedule_close(state)
      true -> state
    end
  end

  defp extended?(events), do: Enum.any?(events, fn {name, _payload} -> name == :extended end)

  # Anti-snipe pushed `closes_at` out: cancel the stale close timer and re-arm
  # from the new deadline so the auction actually stays open.
  defp reschedule_close(state) do
    state |> cancel_close_timer() |> schedule_close()
  end

  defp cancel_close_timer(state) do
    case Map.pop(state.timers, :close) do
      {nil, _timers} ->
        state

      {ref, timers} ->
        Process.cancel_timer(ref)
        %{state | timers: timers}
    end
  end

  defp cancel_timers(state) do
    Enum.each(state.timers, fn {_key, ref} -> Process.cancel_timer(ref) end)
    %{state | timers: %{}}
  end

  defp rehydrate(auction) do
    case store().load(auction.id) do
      {:ok, dumped} -> Auction.load(dumped)
      :error -> auction
    end
  end

  # Clock formats implement `Gavel.Type.Clock`, so `start_clock/1` is guaranteed
  # for any `:clock` kind. Skip on rehydrate, when `extra` is already populated.
  defp maybe_start_clock(%Auction{type: type, extra: extra} = auction) do
    if type.kind() == :clock and map_size(extra) == 0 do
      type.start_clock(auction)
    else
      auction
    end
  end

  defp arm_timers(state) do
    state
    |> schedule_tick()
    |> schedule_notice()
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

  # Uniform integer in [min_delay, max_delay]. :rand.uniform(n) returns 1..n,
  # so this yields min..max inclusive and collapses to min when min == max.
  defp draw_delay(config) do
    min = Map.get(config, :min_delay, 0)
    max = Map.fetch!(config, :max_delay)
    min + :rand.uniform(max - min + 1) - 1
  end

  defp broadcast(id, event) do
    case Application.get_env(:gavel, :pubsub) do
      nil -> :ok
      pubsub -> Phoenix.PubSub.broadcast(pubsub, "auction:#{id}", {:gavel, id, event})
    end
  end

  defp store, do: Application.get_env(:gavel, :store, Gavel.Store.ETS)
  defp now, do: DateTime.utc_now()
end
