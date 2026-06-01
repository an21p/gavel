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
    if auction.status == :closed, do: cancel_timers(state), else: state
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
