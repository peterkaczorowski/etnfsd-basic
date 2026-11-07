defmodule Tnfs.StatusTest do
  use ExUnit.Case, async: true

  alias Tnfs.Status

  test "codes and names are a bijection" do
    codes = Enum.map(Status.all(), &elem(&1, 0))
    names = Enum.map(Status.all(), &elem(&1, 1))

    assert length(Enum.uniq(codes)) == length(codes)
    assert length(Enum.uniq(names)) == length(names)

    for {code, name} <- Status.all() do
      assert Status.code(name) == code
      assert Status.fetch_name(code) == {:ok, name}
      assert Status.known?(name)
    end
  end

  test "golden wire values from the handoff table" do
    assert Status.code(:success) == 0x00
    assert Status.code(:eperm) == 0x01
    assert Status.code(:einval) == 0x0E
    assert Status.code(:eproto) == 0x1B
    assert Status.code(:eof) == 0x21
    assert Status.code(:ebadsession) == 0xFF
  end

  test "unassigned codes are reported, never guessed" do
    assigned = MapSet.new(Enum.map(Status.all(), &elem(&1, 0)))

    for code <- 0..255, not MapSet.member?(assigned, code) do
      assert Status.fetch_name(code) == :error
    end
  end

  test "unknown names are not treated as statuses" do
    refute Status.known?(:nonsense)
    refute Status.known?(:edquot)
  end
end
