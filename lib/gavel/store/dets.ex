defmodule Gavel.Store.DETS do
  @moduledoc "File-backed DETS store. Single-node durability across node restarts."
  @behaviour Gavel.Store

  @table :gavel_auctions_dets

  @impl true
  def init(opts) do
    # If the named table is already open (e.g. from a previous test run or a
    # prior call in the same process), close it first so we can reopen it
    # pointing at the new path. Silently ignore errors if it was not open.
    if :dets.info(@table) != :undefined do
      :dets.close(@table)
    end

    path = Keyword.fetch!(opts, :path) |> to_charlist()
    {:ok, @table} = :dets.open_file(@table, file: path, type: :set)
    :ok
  end

  @doc "Close the DETS file (flushes to disk)."
  def close, do: :dets.close(@table)

  @impl true
  def save(id, dumped) do
    :ok = :dets.insert(@table, {id, dumped})
    :ok = :dets.sync(@table)
  end

  @impl true
  def load(id) do
    case :dets.lookup(@table, id) do
      [{^id, dumped}] -> {:ok, dumped}
      [] -> :error
    end
  end

  @impl true
  def delete(id) do
    :dets.delete(@table, id)
    :ok
  end

  @impl true
  def all do
    :dets.foldl(fn {_id, dumped}, acc -> [dumped | acc] end, [], @table)
  end
end
