defmodule Gavel.Type.ClockTest do
  use ExUnit.Case, async: true

  alias Gavel.Type
  alias Gavel.Type.Clock
  alias Gavel.Types.{Dutch, English, Japanese, Reverse, SealedFirstPrice, Vickrey}

  defp behaviours(mod) do
    mod.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end

  test "the Clock behaviour declares start_clock/1 and tick/2" do
    callbacks = Clock.behaviour_info(:callbacks)
    assert {:start_clock, 1} in callbacks
    assert {:tick, 2} in callbacks
  end

  test "tick/2 is no longer a Gavel.Type callback (it moved to Gavel.Type.Clock)" do
    refute {:tick, 2} in Type.behaviour_info(:callbacks)
  end

  test "clock formats implement both Gavel.Type and Gavel.Type.Clock" do
    for mod <- [Dutch, Japanese] do
      assert Type in behaviours(mod)
      assert Clock in behaviours(mod)
    end
  end

  test "non-clock formats do not implement Gavel.Type.Clock" do
    for mod <- [English, Vickrey, SealedFirstPrice, Reverse] do
      assert Type in behaviours(mod)
      refute Clock in behaviours(mod)
    end
  end
end
