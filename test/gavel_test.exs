defmodule GavelTest do
  use ExUnit.Case
  doctest Gavel

  test "greets the world" do
    assert Gavel.hello() == :world
  end
end
