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
  def place_bid(id, bidder, amount),
    do: Server.place_bid(Server.via(id), bidder: bidder, amount: amount)

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
