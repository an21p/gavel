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
