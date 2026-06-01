defmodule Gavel.Store.DETSTest do
  use ExUnit.Case, async: false
  alias Gavel.Store.DETS

  setup do
    path = Path.join(System.tmp_dir!(), "gavel_test_#{System.unique_integer([:positive])}.dets")
    :ok = DETS.init(path: path)
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "save then load round-trips" do
    :ok = DETS.save("a1", %{id: "a1", status: :open})
    assert {:ok, %{id: "a1", status: :open}} = DETS.load("a1")
  end

  test "data survives a close/reopen of the table", %{path: path} do
    :ok = DETS.save("a1", %{id: "a1"})
    :ok = DETS.close()
    :ok = DETS.init(path: path)
    assert {:ok, %{id: "a1"}} = DETS.load("a1")
  end
end
