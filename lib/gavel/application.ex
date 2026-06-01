defmodule Gavel.Application do
  @moduledoc """
  OTP Application entry point for Gavel.

  Starts the Gavel supervision tree and initialises the configured store.

  ## Supervision tree

  ```
  Gavel.Supervisor (one_for_one)
  ├── Registry (unique, name: Gavel.Registry)
  └── DynamicSupervisor (name: Gavel.DynamicSupervisor, strategy: one_for_one)
  ```

  - **`Gavel.Registry`** — a unique `Registry` used by `Gavel.Server.via/1` to
    register and look up auction processes by id without holding pids.
  - **`Gavel.DynamicSupervisor`** — supervises `Gavel.Server` children that are
    started on demand (one per auction).

  ## Store initialisation

  Before starting the supervision tree, `start/2` reads the `:gavel, :store`
  and `:gavel, :store_opts` application environment keys (defaulting to
  `Gavel.Store.ETS` and `[]` respectively) and calls `store.init(store_opts)`.
  This ensures the persistence layer is ready before any `Gavel.Server` process
  starts and attempts to rehydrate.
  """
  use Application

  @impl true
  def start(_type, _args) do
    store = Application.get_env(:gavel, :store, Gavel.Store.ETS)
    store_opts = Application.get_env(:gavel, :store_opts, [])
    :ok = store.init(store_opts)

    children = [
      {Registry, keys: :unique, name: Gavel.Registry},
      {DynamicSupervisor, name: Gavel.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Gavel.Supervisor)
  end
end
