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
