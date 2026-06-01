defmodule Gavel.Types.Helpers do
  @moduledoc "Pure helpers shared across auction formats."

  alias Gavel.Auction

  @doc "Bids ranked highest amount first; ties broken by earliest `placed_at`."
  def ranked_desc(bids) do
    Enum.sort(bids, fn a, b ->
      case Decimal.compare(a.amount, b.amount) do
        :gt -> true
        :lt -> false
        :eq -> DateTime.compare(a.placed_at, b.placed_at) != :gt
      end
    end)
  end

  @doc "Bids ranked lowest amount first; ties broken by earliest `placed_at`. (reverse auctions)"
  def ranked_asc(bids) do
    Enum.sort(bids, fn a, b ->
      case Decimal.compare(a.amount, b.amount) do
        :lt -> true
        :gt -> false
        :eq -> DateTime.compare(a.placed_at, b.placed_at) != :gt
      end
    end)
  end

  @doc "The current highest bid, or nil."
  def highest(bids), do: bids |> ranked_desc() |> List.first()

  @doc "`true` when `amount` beats `floor` by at least `min_increment` (nil increment ⇒ any strictly-higher amount)."
  def meets_increment?(amount, nil, nil), do: Decimal.compare(amount, Decimal.new(0)) == :gt
  def meets_increment?(amount, nil, _min), do: Decimal.compare(amount, Decimal.new(0)) == :gt

  def meets_increment?(amount, %Decimal{} = current, nil) do
    Decimal.compare(amount, current) == :gt
  end

  def meets_increment?(amount, %Decimal{} = current, %Decimal{} = min) do
    Decimal.compare(amount, Decimal.add(current, min)) != :lt
  end

  @doc "Reserve from config, or nil."
  def reserve(%Auction{config: config}), do: Map.get(config, :reserve_price)

  @doc "`true` when a winning amount clears the reserve (no reserve ⇒ always true)."
  def clears_reserve?(_amount, nil), do: true
  def clears_reserve?(%Decimal{} = amount, %Decimal{} = reserve), do: Decimal.compare(amount, reserve) != :lt

  @doc """
  Applies anti-snipe: if `now` is within the config window of `closes_at`, push
  `closes_at` out by the configured seconds and emit an `:extended` event.
  Returns `{auction, events}`.
  """
  def maybe_extend(%Auction{config: config, closes_at: closes_at} = auction, %DateTime{} = now)
      when not is_nil(closes_at) do
    case Map.get(config, :anti_snipe) do
      %{window: window_s, extend_by: extend_s} ->
        remaining = DateTime.diff(closes_at, now, :second)

        if remaining >= 0 and remaining <= window_s do
          new_closes = DateTime.add(closes_at, extend_s, :second)
          {%{auction | closes_at: new_closes}, [{:extended, %{closes_at: new_closes}}]}
        else
          {auction, []}
        end

      _ ->
        {auction, []}
    end
  end

  def maybe_extend(auction, _now), do: {auction, []}

  @doc "Standard guard: reject any action on a non-open auction."
  def ensure_open(%Auction{status: :open}), do: :ok
  def ensure_open(%Auction{}), do: {:error, :auction_closed}
end
