defmodule Gavel.Store do
  @moduledoc """
  Persistence behaviour for live auctions.

  A `Gavel.Store` adapter stores the serialised output of `Gavel.Auction.dump/1`
  keyed by auction id. `Gavel.Server` calls the configured adapter on every state
  transition so that a restarted server can rehydrate from the last persisted
  snapshot.

  ## Built-in adapters

  | Module              | Durability                                       |
  |---------------------|--------------------------------------------------|
  | `Gavel.Store.ETS`   | Ephemeral — survives process restarts, not node  |
  | `Gavel.Store.DETS`  | File-backed — survives node restarts             |

  ## Implementing a custom adapter

  Any module that implements this behaviour can be used as the store. A
  Postgres-backed adapter, for example, lets Gavel persist across deployments
  without Gavel itself depending on Ecto:

  ```elixir
  defmodule MyApp.AuctionStore do
    @behaviour Gavel.Store

    @impl true
    def init(_opts), do: :ok

    @impl true
    def save(id, dumped) do
      MyApp.Repo.insert!(%MyApp.AuctionRecord{id: id, data: dumped},
        on_conflict: :replace_all, conflict_target: :id
      )
      :ok
    end

    @impl true
    def load(id) do
      case MyApp.Repo.get(MyApp.AuctionRecord, id) do
        nil -> :error
        record -> {:ok, record.data}
      end
    end

    @impl true
    def delete(id) do
      MyApp.Repo.delete_all(from r in MyApp.AuctionRecord, where: r.id == ^id)
      :ok
    end

    @impl true
    def all do
      MyApp.Repo.all(MyApp.AuctionRecord) |> Enum.map(& &1.data)
    end
  end
  ```

  Then configure it in `config/runtime.exs`:

  ```elixir
  config :gavel, store: MyApp.AuctionStore
  ```

  ## Notes on the serialised format

  The dumped map produced by `Gavel.Auction.dump/1` uses tagged tuples for
  `Decimal`, `DateTime`, and `MapSet` values. This format is native-term friendly
  (ETS/DETS round-trip it verbatim) but requires extra handling in a JSON-backed
  store — convert atom keys to strings and round-trip tagged tuples through a
  JSON-safe encoding of your choice.
  """

  @doc """
  Initialise the store.

  Called once at application boot (by `Gavel.Application`) with the value of
  `:gavel, :store_opts` from the application environment (default `[]`). Should
  create tables, open files, or establish connections as needed.

  Returns `:ok` on success; should raise on unrecoverable failure so the
  supervision tree can respond.
  """
  @callback init(opts :: keyword()) :: :ok

  @doc """
  Persist an auction snapshot.

  Stores `dumped` (the plain-map output of `Gavel.Auction.dump/1`) under `id`.
  Overwrites any existing entry for the same `id`. Always returns `:ok`.
  """
  @callback save(id :: term(), dumped :: map()) :: :ok

  @doc """
  Load a previously saved auction snapshot.

  Returns `{:ok, dumped}` if an entry for `id` exists, or `:error` if not found.
  `Gavel.Server` calls this in `init/1` to rehydrate after a process restart.
  """
  @callback load(id :: term()) :: {:ok, map()} | :error

  @doc """
  Remove a saved auction snapshot.

  Deletes the entry for `id`. Idempotent — returns `:ok` even if the id was not
  present.
  """
  @callback delete(id :: term()) :: :ok

  @doc """
  Return all persisted auction snapshots.

  Returns a list of plain maps (the `Gavel.Auction.dump/1` output) for every
  auction currently held by the store. Useful for admin dashboards and recovery
  tooling.
  """
  @callback all() :: [map()]
end
