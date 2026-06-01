defmodule Gavel.Store do
  @moduledoc """
  Persistence behaviour for live auctions. Stores `Gavel.Auction.dump/1` output
  keyed by auction id. Built-in adapters: `Gavel.Store.ETS` (default, ephemeral)
  and `Gavel.Store.DETS` (file-backed). Consumers may implement their own (e.g.
  a Postgres-backed adapter) without `Gavel` depending on a database.
  """

  @callback init(opts :: keyword()) :: :ok
  @callback save(id :: term(), dumped :: map()) :: :ok
  @callback load(id :: term()) :: {:ok, map()} | :error
  @callback delete(id :: term()) :: :ok
  @callback all() :: [map()]
end
