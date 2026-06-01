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
