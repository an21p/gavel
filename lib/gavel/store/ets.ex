defmodule Gavel.Store.ETS do
  @moduledoc "Ephemeral ETS-backed store. Survives process restarts, not node restarts."
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
