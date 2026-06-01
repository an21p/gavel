defmodule Gavel.Bid do
  @moduledoc """
  A single bid placed in an auction.

  `Gavel.Bid` is a plain data struct — it carries no business logic.  Bids are
  created by `Gavel.Server` when a participant calls `Gavel.place_bid/3` or
  `Gavel.set_max_bid/3`, then passed to the appropriate `Gavel.Type` callback
  for validation.

  Amounts are always stored as `Decimal` values regardless of the input type
  so that arithmetic across the system is consistent and lossless.
  """

  @enforce_keys [:bidder, :amount, :placed_at]
  defstruct [:bidder, :amount, :max_amount, :placed_at]

  @typedoc """
  A bid in an auction.

    * `:bidder` — an opaque identifier for the participant (any term, typically
      a user ID or name string).
    * `:amount` — the explicit bid price as a `Decimal`.
    * `:max_amount` — the optional proxy ceiling used by English-style auto-bid
      logic; `nil` when not set.
    * `:placed_at` — the UTC wall-clock time the bid was recorded.
  """
  @type t :: %__MODULE__{
          bidder: term(),
          amount: Decimal.t(),
          max_amount: Decimal.t() | nil,
          placed_at: DateTime.t()
        }

  @doc """
  Builds a `Gavel.Bid`, coercing `amount` and `max_amount` to `Decimal`.

  Accepts a keyword list or map with the following keys:

    * `:bidder` (required) — any term identifying the participant.
    * `:amount` (required) — the bid price as a `Decimal`, integer, or numeric
      string.  Passed to `Decimal.new/1` when not already a `Decimal`.
    * `:max_amount` (optional) — proxy ceiling for English auto-bidding; same
      coercion as `:amount`.  Defaults to `nil`.
    * `:placed_at` (required) — a `DateTime` representing when the bid was
      recorded.

  Returns a `%Gavel.Bid{}` struct.  Raises `KeyError` if a required key is
  missing, or `Decimal.Error` if an amount cannot be parsed.
  """
  @spec new(keyword() | map()) :: t()
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
