defmodule Gavel.Store.ETS do
  @moduledoc """
  Ephemeral ETS-backed store. Survives process restarts, not node restarts.

  This is the default store when no `:gavel, :store` application environment
  key is set. It keeps all auction snapshots in a named public ETS table called
  `:gavel_auctions`. Because the table is named and public it outlives any
  individual `Gavel.Server` process — a restarted server can rehydrate from ETS
  even if it crashed mid-auction.

  Data does **not** survive node restarts or application stops. For durable
  storage use `Gavel.Store.DETS` or implement a custom `Gavel.Store` adapter.

  No configuration is required. `Gavel.Application` calls `init/1` at boot
  with an empty options list.
  """
  @behaviour Gavel.Store

  @table :gavel_auctions

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @impl true
  def save(id, dumped) do
    :ets.insert(@table, {id, dumped})
    :ok
  end

  @impl true
  def load(id) do
    case :ets.lookup(@table, id) do
      [{^id, dumped}] -> {:ok, dumped}
      [] -> :error
    end
  end

  @impl true
  def delete(id) do
    :ets.delete(@table, id)
    :ok
  end

  @impl true
  def all do
    :ets.tab2list(@table) |> Enum.map(fn {_id, dumped} -> dumped end)
  end
end
