defmodule Gavel.Store.ETSTest do
  use ExUnit.Case, async: false
  alias Gavel.Store.ETS

  setup do
    :ok = ETS.init([])

    on_exit(fn ->
      if :ets.whereis(:gavel_auctions) != :undefined, do: :ets.delete_all_objects(:gavel_auctions)
    end)

    :ok
  end

  test "save then load round-trips" do
    :ok = ETS.save("a1", %{id: "a1", status: :open})
    assert {:ok, %{id: "a1", status: :open}} = ETS.load("a1")
  end

  test "load of a missing id is :error" do
    assert :error = ETS.load("nope")
  end

  test "delete removes the row" do
    :ok = ETS.save("a1", %{id: "a1"})
    :ok = ETS.delete("a1")
    assert :error = ETS.load("a1")
  end

  test "all/0 lists every stored dump" do
    :ok = ETS.save("a1", %{id: "a1"})
    :ok = ETS.save("a2", %{id: "a2"})
    ids = ETS.all() |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["a1", "a2"]
  end
end
