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
