defmodule Gavel.Auction do
  @moduledoc """
  The auction state struct and its pure lifecycle functions.

  `Gavel.Auction` is the central data structure of the Gavel library.  It is a
  plain Elixir struct with no process or side-effect of its own — all mutations
  happen through the pure functions in this module, which are called by
  `Gavel.Server` (the OTP process that owns a live auction) and by the
  `Gavel.Type` callbacks that implement each auction format.

  ## Lifecycle

  An auction moves through three statuses:

    1. **`:pending`** — created by `new/1` from a raw config map.  The auction
       has not started yet; no bids are accepted.
    2. **`:open`** — transitioned by `open/2` once the server starts.  Bids and
       clock ticks are processed in this state.
    3. **`:closed`** — set by `c:Gavel.Type.resolve/2` when the auction ends
       (either at `closes_at` or via `Gavel.close/1`).  The `:result` field is
       populated.

  ## The `:phase` field

  `:phase` carries format-specific sub-state for `:sealed` auction types.  For
  example, a Vickrey or sealed-first-price auction uses `:bidding` during the
  open window and `:reveal` after bids close.  For `:open` and `:clock` formats
  `:phase` is `nil`.

  ## Persistence — `dump/1` and `load/1`

  `dump/1` serialises an `%Auction{}` to a plain Elixir map suitable for storage
  in ETS, DETS, or any native-term store (the built-in `Gavel.Store.ETS`
  backend uses it).  The encoding rules are:

    * `Decimal` values become strings tagged `{:dec, "…"}`.
    * `DateTime` values become ISO 8601 strings tagged `{:dt, "…"}`.
    * `MapSet` values become tagged lists `{:set, […]}`.
    * The `:type` module atom is stored as a string via `Atom.to_string/1`.
    * Atom tags for `:status`, `:phase`, and `:result` are preserved as-is;
      a JSON-backed store would need to handle those on the way back in.

  `load/1` is the inverse, restoring a full `%Auction{}` from `dump/1` output.
  """

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

  @typedoc "The current lifecycle status of an auction."
  @type status :: :pending | :open | :closed

  @typedoc """
  The terminal outcome stored in `:result` once an auction is `:closed`.

  `{:sold, bidder, price}` identifies the winner and clearing price.
  `:no_sale` means the auction ended without a qualifying bid (e.g. reserve not
  met).  `nil` while the auction is still `:pending` or `:open`.
  """
  @type result :: {:sold, term(), Decimal.t()} | :no_sale | nil

  @typedoc """
  A live or historical auction.

    * `:id` — opaque identifier supplied in the config; used as the registry key
      and PubSub topic suffix.
    * `:type` — the `Gavel.Type` implementation module (e.g. `Gavel.Types.English`).
    * `:status` — see `t:status/0`.
    * `:phase` — format-specific sub-state; used by `:sealed` types; `nil` otherwise.
    * `:config` — the raw config map passed to `new/1`, including the `:type` key.
    * `:bids` — chronological list of `Gavel.Bid` structs.
    * `:opened_at` — UTC timestamp set by `open/2`; `nil` until then.
    * `:closes_at` — optional hard deadline; `Gavel.Server` arms a timer to call
      `resolve/2` at this time.
    * `:result` — see `t:result/0`.
    * `:extra` — arbitrary map for type-specific ephemeral state (clock price,
      participant sets, etc.).
  """
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

  @doc """
  Builds a `:pending` auction from a config map.

  The config map must contain at least:

    * `:type` — a module that implements `Gavel.Type`.
    * `:id` — an opaque identifier for the auction (any term).

  Any additional keys are passed through to the type's `validate_config/1`
  callback and stored verbatim in `:config`.

  Returns `{:ok, %Gavel.Auction{}}` on success, or `{:error, reason}` if the
  type's `validate_config/1` rejects the config.  Raises `KeyError` if `:type`
  is missing from the map.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
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

  @doc """
  Transitions a `:pending` auction to `:open`.

  Sets `:status` to `:open` and records `now` as `:opened_at`.  The auction is
  ready to receive bids after this call.  Returns the updated `%Gavel.Auction{}`
  directly (this is a pure struct mutation, not a tagged tuple).
  """
  @spec open(t(), DateTime.t()) :: t()
  def open(%__MODULE__{} = auction, %DateTime{} = now) do
    %{auction | status: :open, opened_at: now}
  end

  @doc """
  Appends a bid to the auction's bid list in chronological order.

  Returns the updated `%Gavel.Auction{}`.  This function does not validate the
  bid — validation is the responsibility of the `c:Gavel.Type.place_bid/3`
  callback, which calls this function only after confirming the bid is
  acceptable.
  """
  @spec put_bid(t(), Bid.t()) :: t()
  def put_bid(%__MODULE__{} = auction, %Bid{} = bid) do
    %{auction | bids: auction.bids ++ [bid]}
  end

  @doc """
  Returns `true` if the auction is in the `:open` status, `false` otherwise.

  Use this guard before applying any action (bid, tick, drop-out) to avoid
  mutating a `:pending` or `:closed` auction.
  """
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{status: :open}), do: true
  def open?(%__MODULE__{}), do: false

  @doc """
  Serialises an auction struct to a plain map for native-term persistence.

  The output is suitable for storage in ETS, DETS, or any store backed by
  Erlang terms.  All `Decimal` values are encoded as `{:dec, string}` tuples,
  `DateTime` values as `{:dt, iso8601_string}` tuples, and `MapSet` values as
  `{:set, list}` tuples.  The `:type` module atom is stored as a string.  Atom
  tags for `:status`, `:phase`, and `:result` are preserved as-is.

  Pass the return value to `load/1` to reconstruct the struct.
  """
  @spec dump(t()) :: map()
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

  @doc """
  Rebuilds a `%Gavel.Auction{}` from the output of `dump/1`.

  Reverses all encoding applied by `dump/1`: `{:dec, s}` → `Decimal`, `{:dt,
  s}` → `DateTime`, `{:set, list}` → `MapSet`, and the `:type` string →
  existing atom (via `String.to_existing_atom/1`).  Raises if the type module
  atom is not already loaded.
  """
  @spec load(map()) :: t()
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
