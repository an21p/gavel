defmodule Gavel.Type do
  @moduledoc """
  The behaviour every auction format implements.

  Each auction type module must implement this behaviour.  The callbacks are
  pure functions: they receive a `Gavel.Auction` struct plus an explicit `now`
  (`DateTime.t()`) so that all logic is deterministic and testable without
  mocking the clock.  They never raise on bad input — errors are returned as
  `{:error, reason}` tuples.

  ## `kind/0` values

  The `:kind` determines how the lifecycle initialises and drives the auction:

    * `:open`   — bids are visible to all participants as they arrive; no `:phase`
                  field is used (e.g. English / ascending-price auctions).
    * `:sealed` — bids are hidden until the auction closes; the `:phase` field
                  on `Gavel.Auction` tracks the current sub-state (e.g. Vickrey,
                  sealed-first-price, reverse auctions).
    * `:clock`  — the auction price moves on a timer; these formats additionally
                  implement the `Gavel.Type.Clock` behaviour (`start_clock/1` +
                  `tick/2`), e.g. Dutch descending-clock and Japanese
                  ascending-clock. Japanese also implements the optional
                  `drop_out/3` callback below.

  ## Return shapes

  All action callbacks return either:

    * `{:ok, auction, events}` — success; `events` is a keyword-like list of
      `{event_name, payload_map}` tuples that `Gavel.Server` broadcasts on the
      auction's PubSub topic.
    * `{:error, reason}` — the action was rejected; `reason` is an atom such as
      `:auction_closed`, `:below_minimum`, `:already_bid`, `:not_a_participant`,
      etc. (exact atoms are type-specific).

  ## Optional callbacks

  `drop_out/3` is optional (`@optional_callbacks`) — only Japanese implements it.
  The price-clock callbacks live in the separate `Gavel.Type.Clock` behaviour,
  which `:clock` formats implement in addition to this one.
  """

  alias Gavel.{Auction, Bid}

  @typedoc "A list of named events emitted by an auction action, each a `{event_name, payload}` pair."
  @type events :: [{atom(), map()}]

  @typedoc "The terminal result of a resolved auction."
  @type result :: {:sold, bidder :: term(), price :: Decimal.t()} | :no_sale

  @doc """
  Returns the kind of this auction format.

  Used by `Gavel.Auction.new/1` to set the initial `:phase` and by
  `Gavel.Server` to decide whether to arm the tick timer.
  """
  @callback kind() :: :open | :sealed | :clock

  @doc """
  Validates a raw config map before an auction is created.

  Returns `:ok` if the config is acceptable, or `{:error, reason}` with a
  descriptive atom or string if required keys are missing or values are out of
  range.  Called from `Gavel.Auction.new/1`.
  """
  @callback validate_config(config :: map()) :: :ok | {:error, term()}

  @doc """
  Applies a bid to an open auction.

  Receives the current auction struct, the new `Gavel.Bid`, and the current
  wall-clock time.  Returns `{:ok, updated_auction, events}` on success or
  `{:error, reason}` if the bid is invalid (e.g. below reserve, auction
  already closed, duplicate bidder in sealed format).
  """
  @callback place_bid(Auction.t(), Bid.t(), now :: DateTime.t()) ::
              {:ok, Auction.t(), events()} | {:error, term()}

  @doc """
  Resolves the auction and produces its final result.

  Called either when the scheduled `closes_at` time is reached or when
  `Gavel.close/1` is invoked explicitly.  Always returns
  `{:ok, closed_auction, events}` — resolution itself does not fail; the
  auction transitions to `:closed` with a `:result` of `{:sold, bidder, price}`
  or `:no_sale`.
  """
  @callback resolve(Auction.t(), now :: DateTime.t()) :: {:ok, Auction.t(), events()}

  @doc "Withdraw a bidder. Only Japanese implements this."
  @callback drop_out(Auction.t(), bidder :: term(), now :: DateTime.t()) ::
              {:ok, Auction.t(), events()} | {:error, term()}

  @optional_callbacks drop_out: 3
end
