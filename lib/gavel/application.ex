defmodule Gavel.Application do
  @moduledoc false
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
