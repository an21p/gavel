defmodule Gavel.Auction do
  @moduledoc "The auction state struct and its pure lifecycle functions."

  alias Gavel.Bid

  @enforce_keys [:type, :status, :config]
  defstruct id: nil,
            type: nil,
            status: :pending,
            phase: nil,
            config: %{},
            bids: [],
            opened_at: nil,
            closes_at: nil,
            result: nil,
            extra: %{}

  @type status :: :pending | :open | :closed
  @type result :: {:sold, term(), Decimal.t()} | :no_sale | nil
  @type t :: %__MODULE__{
          id: term(),
          type: module(),
          status: status(),
          phase: atom() | nil,
          config: map(),
          bids: [Bid.t()],
          opened_at: DateTime.t() | nil,
          closes_at: DateTime.t() | nil,
          result: result(),
          extra: map()
        }

  @doc "Builds a `:pending` auction from a config map. Returns `{:error, reason}` if the type rejects the config."
  def new(config) when is_map(config) do
    type = Map.fetch!(config, :type)

    case type.validate_config(config) do
      :ok ->
        {:ok,
         %__MODULE__{
           id: Map.get(config, :id),
           type: type,
           status: :pending,
           phase: initial_phase(type),
           config: config,
           bids: [],
           closes_at: Map.get(config, :closes_at),
           extra: %{}
         }}

      {:error, _reason} = err ->
        err
    end
  end

  defp initial_phase(type) do
    case type.kind() do
      :sealed -> :bidding
      _ -> nil
    end
  end

  @doc "Transitions a pending auction to `:open`."
  def open(%__MODULE__{} = auction, %DateTime{} = now) do
    %{auction | status: :open, opened_at: now}
  end

  @doc "Appends a bid (chronological order)."
  def put_bid(%__MODULE__{} = auction, %Bid{} = bid) do
    %{auction | bids: auction.bids ++ [bid]}
  end

  @doc "Whether the auction is still accepting actions."
  def open?(%__MODULE__{status: :open}), do: true
  def open?(%__MODULE__{}), do: false

  @doc """
  Serialises to a plain map suitable for native-term persistence (the built-in
  ETS/DETS stores). `Decimal`s and `DateTime`s become strings; `MapSet`s become
  tagged lists. Status/phase/result tag atoms are preserved as-is, so a JSON-backed
  store would additionally need to handle those atoms on the way back in.
  """
  def dump(%__MODULE__{} = a) do
    %{
      id: a.id,
      type: Atom.to_string(a.type),
      status: a.status,
      phase: a.phase,
      config: dump_config(a.config),
      bids: Enum.map(a.bids, &dump_bid/1),
      opened_at: dump_dt(a.opened_at),
      closes_at: dump_dt(a.closes_at),
      result: dump_result(a.result),
      extra: dump_extra(a.extra)
    }
  end

  @doc "Rebuilds an `%Auction{}` from `dump/1` output."
  def load(%{} = m) do
    %__MODULE__{
      id: m.id,
      type: String.to_existing_atom(m.type),
      status: m.status,
      phase: m.phase,
      config: load_config(m.config),
      bids: Enum.map(m.bids, &load_bid/1),
      opened_at: load_dt(m.opened_at),
      closes_at: load_dt(m.closes_at),
      result: load_result(m.result),
      extra: load_extra(m.extra)
    }
  end

  # --- dump/load helpers: every Decimal becomes a string and back ---

  defp dump_bid(%Bid{} = b) do
    %{
      bidder: b.bidder,
      amount: dec(b.amount),
      max_amount: dec(b.max_amount),
      placed_at: dump_dt(b.placed_at)
    }
  end

  defp load_bid(%{} = m) do
    Bid.new(
      bidder: m.bidder,
      amount: m.amount,
      max_amount: m.max_amount,
      placed_at: load_dt(m.placed_at)
    )
  end

  defp dump_config(config), do: Map.new(config, fn {k, v} -> {k, dump_val(v)} end)
  defp load_config(config), do: Map.new(config, fn {k, v} -> {k, load_config_val(k, v)} end)

  defp dump_extra(extra), do: Map.new(extra, fn {k, v} -> {k, dump_val(v)} end)
  defp load_extra(extra), do: Map.new(extra, fn {k, v} -> {k, load_decoded_val(v)} end)

  # config/extra values may be Decimals, atoms, DateTimes, MapSets, plain terms.
  defp dump_val(%Decimal{} = d), do: {:dec, dec(d)}
  defp dump_val(%DateTime{} = dt), do: {:dt, dump_dt(dt)}
  defp dump_val(%MapSet{} = s), do: {:set, MapSet.to_list(s)}
  defp dump_val(other), do: other

  # The :type key in config holds a module atom. dump_val passes it through unchanged
  # (via the catch-all), so load_config_val must handle both the atom case (round-trip from
  # in-memory dump) and the string case (load from JSON storage where it would be a string).
  defp load_config_val(:type, v) when is_atom(v), do: v
  defp load_config_val(:type, v) when is_binary(v), do: String.to_existing_atom(v)
  defp load_config_val(_k, v), do: load_decoded_val(v)

  defp load_decoded_val({:dec, s}), do: Decimal.new(s)
  defp load_decoded_val({:dt, s}), do: load_dt(s)
  defp load_decoded_val({:set, list}), do: MapSet.new(list)
  defp load_decoded_val(other), do: other

  defp dump_result({:sold, bidder, price}), do: {:sold, bidder, dec(price)}
  defp dump_result(other), do: other
  defp load_result({:sold, bidder, price}), do: {:sold, bidder, Decimal.new(price)}
  defp load_result(other), do: other

  defp dec(nil), do: nil
  defp dec(%Decimal{} = d), do: Decimal.to_string(d)

  defp dump_dt(nil), do: nil
  defp dump_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp load_dt(nil), do: nil
  defp load_dt(s) when is_binary(s), do: elem(DateTime.from_iso8601(s), 1)
  defp load_dt(%DateTime{} = dt), do: dt
end
