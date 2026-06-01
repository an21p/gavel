defmodule Gavel.Bid do
  @moduledoc "A single bid in an auction."

  @enforce_keys [:bidder, :amount, :placed_at]
  defstruct [:bidder, :amount, :max_amount, :placed_at]

  @type t :: %__MODULE__{
          bidder: term(),
          amount: Decimal.t(),
          max_amount: Decimal.t() | nil,
          placed_at: DateTime.t()
        }

  @doc "Builds a bid, coercing `amount`/`max_amount` to `Decimal`."
  def new(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      bidder: Map.fetch!(attrs, :bidder),
      amount: to_decimal(Map.fetch!(attrs, :amount)),
      max_amount: attrs |> Map.get(:max_amount) |> to_decimal_or_nil(),
      placed_at: Map.fetch!(attrs, :placed_at)
    }
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp to_decimal_or_nil(nil), do: nil
  defp to_decimal_or_nil(other), do: to_decimal(other)
end
