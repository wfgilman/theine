defmodule TheineTest do
  use ExUnit.Case, async: true

  test "the application starts with an empty top-level supervisor" do
    assert {:ok, _} = Application.ensure_all_started(:theine)
    assert Supervisor.count_children(Theine.AppSupervisor).active == 0
  end
end
