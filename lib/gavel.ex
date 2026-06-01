defmodule Gavel do
  @moduledoc """
  Public API for running auctions.

  Gavel is organised as two layers:

    * **Pure core** — `Gavel.Auction`, `Gavel.Bid`, and the `Gavel.Type`
      behaviour are plain Elixir data and functions.  They hold all auction
      logic, are fully synchronous, and have no side-effects.
    * **OTP runtime** — `Gavel.Server` wraps one auction in a `GenServer`,
      managing timers, persistence (via the configured `Gavel.Store`), and
      optional PubSub broadcasts.  `Gavel.DynamicSupervisor` supervises all
      running servers.

  This module is the entry point for the OTP runtime.  It starts auction
  processes and dispatches actions to them via `GenServer.call`.

  ## Quick start

  ```elixir
  # 1. Start an auction (returns {:ok, pid})
  {:ok, _pid} = Gavel.start_auction(%{
    id: "lot-42",
    type: Gavel.Types.English,
    reserve_price: Decimal.new("100.00"),
    closes_at: DateTime.add(DateTime.utc_now(), 3600, :second)
  })

  # 2. Participants place bids
  {:ok, _auction} = Gavel.place_bid("lot-42", "alice", "150.00")
  {:ok, _auction} = Gavel.place_bid("lot-42", "bob", Decimal.new("175.00"))

  # 3. Close (or let closes_at fire automatically)
  {:ok, closed_auction} = Gavel.close("lot-42")
  # => closed_auction.result == {:sold, "bob", Decimal.new("175.00")}
  ```

  See `Gavel.Types.*` for the available formats and their config keys.
  """

  alias Gavel.{Auction, Server}

  @doc """
  Starts a supervised auction process.

  Builds a `Gavel.Auction` from `config`, immediately opens it, then registers
  it under `Gavel.DynamicSupervisor`.  The config map must include:

    * `:id` — a unique identifier (any term) used as the process registry key
      and PubSub topic suffix.
    * `:type` — a module implementing `Gavel.Type` (e.g. `Gavel.Types.English`).

  Any additional keys are forwarded to the type's `validate_config/1` callback
  (see the specific `Gavel.Types.*` module for required keys such as
  `:reserve_price`, `:closes_at`, or `:tick_interval_ms`).

  Returns `{:ok, pid}` on success or `{:error, reason}` from
  `DynamicSupervisor.start_child/2` if the process cannot be registered (e.g.
  duplicate `:id`).  Raises `ArgumentError` if the type rejects the config — this
  is treated as a programmer error (bad static config), not a runtime one.
  """
  @spec start_auction(map()) :: DynamicSupervisor.on_start_child()
  def start_auction(config) when is_map(config) do
    case Auction.new(config) do
      {:ok, auction} ->
        auction = Auction.open(auction, DateTime.utc_now())
        DynamicSupervisor.start_child(Gavel.DynamicSupervisor, {Server, auction: auction})

      {:error, reason} ->
        raise ArgumentError, "invalid auction config: #{inspect(reason)}"
    end
  end

  @doc """
  Places a bid in an open auction.

  Looks up the auction server for `id` in the registry and delegates to
  `c:Gavel.Type.place_bid/3`.  `amount` is coerced to `Decimal` by `Gavel.Bid.new/1`
  and may be a `Decimal`, integer, or numeric string.

  Returns `{:ok, %Gavel.Auction{}}` with the updated state on success, or
  `{:error, reason}` if the bid is rejected by the type (e.g. `:bid_too_low`,
  `:below_min_increment`, `:auction_closed`). A bid below a `:reserve_price`
  is not rejected here; it surfaces as a `:no_sale` result at resolution.
  """
  @spec place_bid(term(), term(), Decimal.t() | integer() | String.t()) ::
          {:ok, Auction.t()} | {:error, atom()}
  def place_bid(id, bidder, amount),
    do: Server.place_bid(Server.via(id), bidder: bidder, amount: amount)

  @doc """
  Sets a proxy max bid (English auctions only).

  Submits a bid where both `:amount` and `:max_amount` are set to `max`.  The
  English type's auto-bid logic will advance the visible bid incrementally up to
  `max` as competing bids arrive.

  Returns `{:ok, %Gavel.Auction{}}` or `{:error, reason}`.
  """
  @spec set_max_bid(term(), term(), Decimal.t() | integer() | String.t()) ::
          {:ok, Auction.t()} | {:error, atom()}
  def set_max_bid(id, bidder, max), do: Server.set_max_bid(Server.via(id), bidder, max)

  @doc """
  Accepts the current clock price in a Dutch auction.

  Signals the bidder's willingness to buy at whatever price the descending clock
  currently shows.  Implemented as a bid with `amount: 0`; only `Gavel.Types.Dutch`
  treats it as an acceptance at the current clock price.  Other formats receive it
  as an ordinary (zero-amount) bid and will typically reject it (e.g.
  `{:error, :bid_too_low}`), so use this only on Dutch auctions.

  Returns `{:ok, %Gavel.Auction{}}` or `{:error, reason}`.
  """
  @spec accept(term(), term()) :: {:ok, Auction.t()} | {:error, atom()}
  def accept(id, bidder), do: Server.accept(Server.via(id), bidder)

  @doc """
  Drops out of a Japanese auction.

  Signals that the bidder is no longer willing to continue at the current
  ascending clock price.  Only `Gavel.Types.Japanese` implements
  `c:Gavel.Type.drop_out/3`; calling this on other auction types will raise or
  return an error.

  Returns `{:ok, %Gavel.Auction{}}` or `{:error, reason}`.
  """
  @spec drop_out(term(), term()) :: {:ok, Auction.t()} | {:error, atom()}
  def drop_out(id, bidder), do: Server.drop_out(Server.via(id), bidder)

  @doc """
  Returns the current auction state.

  Fetches the live `%Gavel.Auction{}` struct from the running server.  Applies
  to all auction types.

  Returns the `%Gavel.Auction{}` struct directly (not wrapped in a tuple).
  Raises if no process is registered under `id`.
  """
  @spec get(term()) :: Auction.t()
  def get(id), do: Server.get(Server.via(id))

  @doc """
  Resolves the auction immediately, regardless of `closes_at`.

  Calls `c:Gavel.Type.resolve/2` on the running server, transitioning the auction
  to `:closed` and populating `:result`.  If the auction is already closed, the
  current state is returned unchanged.

  Applies to all auction types.  Returns `{:ok, %Gavel.Auction{}}`.
  """
  @spec close(term()) :: {:ok, Auction.t()}
  def close(id), do: Server.close(Server.via(id))
end
