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
         :ok <- check_admissible(auction, bid) do
      prior = Helpers.highest(auction.bids)
      auction = auction |> Auction.put_bid(bid) |> recompute_visible_amounts()
      {auction, extend_events} = Helpers.maybe_extend(auction, now)

      events =
        [{:bid_placed, %{bid: bid}}] ++
          outbid_event(prior, Helpers.highest(auction.bids)) ++
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

  # A bid is admissible if its *ceiling* (max_amount or amount) can beat the
  # current leader by the increment.
  defp check_admissible(auction, bid) do
    ceiling = bid.max_amount || bid.amount
    current = current_amount(auction)
    min = Map.get(auction.config, :min_increment)

    cond do
      current == nil -> :ok
      Decimal.compare(ceiling, current) != :gt -> {:error, :bid_too_low}
      Helpers.meets_increment?(ceiling, current, min) -> :ok
      true -> {:error, :below_min_increment}
    end
  end

  # Re-derive each bidder's visible amount from the set of ceilings, so the top
  # ceiling leads at one increment over the second ceiling (capped at its own max).
  # Plain (non-proxy) bids keep a visible amount >= their submitted amount.
  defp recompute_visible_amounts(auction) do
    min = Map.get(auction.config, :min_increment) || Decimal.new(0)
    start = Map.get(auction.config, :start_price) || Decimal.new(0)
    ranked = rank_by_ceiling(auction.bids)

    bids =
      case ranked do
        [] -> []
        [leader] -> [%{leader | amount: lone_leader_amount(leader, start)}]
        [leader, runner | rest] -> apply_contested(leader, runner, rest, min, start)
      end

    %{auction | bids: bids}
  end

  # Sort bids by ceiling desc; ties broken by earliest placed_at.
  defp rank_by_ceiling(bids) do
    Enum.sort(bids, fn a, b ->
      case Decimal.compare(ceiling(a), ceiling(b)) do
        :gt -> true
        :lt -> false
        :eq -> DateTime.compare(a.placed_at, b.placed_at) != :gt
      end
    end)
  end

  # Visible amount for a lone leader: proxy shows start_price, plain keeps amount.
  defp lone_leader_amount(%Bid{max_amount: nil, amount: a}, _start), do: a
  defp lone_leader_amount(_proxy_bid, start), do: start

  # Derive visible amounts when there are at least two bidders.
  defp apply_contested(leader, runner, rest, min, start) do
    runner_ceiling = ceiling(runner)
    target = dec_max(dec_min(ceiling(leader), Decimal.add(runner_ceiling, min)), start)
    leader_visible = contested_leader_amount(leader, target)
    runner_visible = dec_max(start, base_amount(runner))
    [%{leader | amount: leader_visible}, %{runner | amount: runner_visible} | rest]
  end

  # For a plain bid, never reduce below the submitted amount.
  # For a proxy bid, use the auto-advanced target directly.
  defp contested_leader_amount(%Bid{max_amount: nil} = leader, target),
    do: dec_max(target, base_amount(leader))

  defp contested_leader_amount(_proxy_bid, target), do: target

  defp ceiling(%Bid{max_amount: nil, amount: a}), do: a
  defp ceiling(%Bid{max_amount: m}), do: m
  defp base_amount(%Bid{amount: a}), do: a
  defp dec_min(a, b), do: if(Decimal.compare(a, b) == :lt, do: a, else: b)
  defp dec_max(a, b), do: if(Decimal.compare(a, b) == :gt, do: a, else: b)

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
