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
      Enum.any?(required, fn key -> not match?(%Decimal{}, Map.get(config, key)) end) ->
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
