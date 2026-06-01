defmodule Gavel.Types.Japanese do
  @moduledoc "Ascending-clock auction: bidders drop out as the price rises; the last one standing wins."
  @behaviour Gavel.Type

  alias Gavel.{Auction, Bid}
  alias Gavel.Types.Helpers

  @impl true
  def kind, do: :clock

  @impl true
  def validate_config(config) do
    if match?(%Decimal{}, Map.get(config, :start_price)) and
         match?(%Decimal{}, Map.get(config, :increment)),
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
      [winner] ->
        close_sold(auction, winner)

      _ ->
        result = :no_sale
        {:ok, %{auction | status: :closed, result: result}, [{:closed, %{result: result}}]}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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
