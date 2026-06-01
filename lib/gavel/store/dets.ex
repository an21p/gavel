defmodule Gavel.Store.DETS do
  @moduledoc """
  File-backed DETS store. Single-node durability across node restarts.

  Auction snapshots are written to a DETS file on disk, so they survive node
  restarts and application crashes (subject to the last `sync` having completed).
  This adapter is suitable for single-node deployments that need durability
  without an external database.

  ## Configuration

  Pass the file path via `:store_opts` in the application environment:

  ```elixir
  config :gavel,
    store: Gavel.Store.DETS,
    store_opts: [path: "/var/lib/myapp/auctions.dets"]
  ```

  `Gavel.Application` calls `init/1` at boot with these opts. The path is
  created if it does not already exist (DETS creates the file on first open).

  ## Shutdown

  Call `close/0` before stopping the application to flush any buffered writes.
  In a supervised application you can do this in a `Supervisor` shutdown hook or
  `Application.stop/1` callback. Omitting `close/0` is safe but may lose the
  last write if the node crashes.

  ## Limitations

  DETS is a single-node technology. It cannot be shared across nodes and does
  not support concurrent writers. For multi-node or high-throughput deployments,
  implement a `Gavel.Store` adapter backed by Postgres or another distributed
  store.
  """
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

  @doc """
  Close the DETS file, flushing all pending writes to disk.

  Should be called on graceful application shutdown. Idempotent — safe to call
  even if the file is already closed.
  """
  @spec close() :: :ok | {:error, term()}
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
