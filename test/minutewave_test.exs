defmodule MinutewaveTest do
  use ExUnit.Case
  doctest Minutewave

  test "greets the world" do
    assert Minutewave.hello() == :world
  end
end
