defmodule Tnfs.GlobTest do
  @moduledoc """
  The OPENDIRX pattern subset, including the cases a hostile pattern would use.
  """

  use ExUnit.Case, async: true

  alias Tnfs.Glob

  defp matches?(name, pattern, fold \\ true) do
    Glob.match?(Glob.compile(pattern, fold), name)
  end

  describe "literals" do
    test "an exact pattern matches only itself" do
      assert matches?("readme.txt", "readme.txt")
      refute matches?("readme.txt2", "readme.txt")
      refute matches?("eadme.txt", "readme.txt")
    end

    test "an empty pattern matches only the empty name" do
      assert matches?("", "")
      refute matches?("a", "")
    end

    test "folding is on unless a case-sensitive match was asked for" do
      assert matches?("README.TXT", "readme.txt")
      refute matches?("README.TXT", "readme.txt", false)
      assert matches?("README.TXT", "README.TXT", false)
    end

    test "bytes above ASCII are compared as they are" do
      assert matches?(<<"caf", 0xC3, 0xA9>>, <<"caf", 0xC3, 0xA9>>)
      refute matches?(<<"caf", 0xC3, 0x89>>, <<"caf", 0xC3, 0xA9>>)
    end
  end

  describe "wildcards" do
    test "* matches any run of bytes, including none" do
      assert matches?("notes.txt", "*.txt")
      assert matches?(".txt", "*.txt")
      assert matches?("anything", "*")
      assert matches?("", "*")
    end

    test "* does not stop at a dot or a slash" do
      # A pattern is matched against one entry name, so there is nothing to
      # stop at.
      assert matches?("a.b.c", "a*c")
      assert matches?("a/b", "a*b")
    end

    test "? matches exactly one byte" do
      assert matches?("cat", "c?t")
      refute matches?("ct", "c?t")
      refute matches?("coat", "c?t")
    end

    test "a pattern may combine both" do
      assert matches?("image001.png", "image???.*")
      refute matches?("image1.png", "image???.*")
    end

    test "many stars do not blow up" do
      # The pattern comes from the network, so the matcher has to be polynomial
      # rather than merely fast in the common case. This is the worst input for
      # a naive matcher: every star can absorb any prefix, nothing ever matches,
      # and backtracking has to try all of it.
      #
      # The sizes are chosen so that the two behaviours are not near each other.
      # With 40 stars over 160 characters a backtracking matcher explores on the
      # order of 2^40 states, which is hours at best; the matcher here does
      # about 160 x 41 steps, which is microseconds.
      #
      # The ceiling is therefore deliberately enormous rather than tight. An
      # earlier version asserted 100 ms and duly failed inside a container at
      # 164 ms - it was measuring how busy the machine was, not whether the
      # algorithm was exponential. Two seconds cannot be reached by anything
      # polynomial on any machine that can run the rest of this suite, and
      # cannot be met by anything exponential on any machine at all.
      name = String.duplicate("a", 160)
      pattern = String.duplicate("*a", 40) <> "b"

      assert {time, false} = :timer.tc(fn -> matches?(name, pattern) end)
      assert time < 2_000_000
    end
  end

  describe "sets" do
    test "a set matches any of its members" do
      assert matches?("a.c", "[abc].c")
      assert matches?("b.c", "[abc].c")
      refute matches?("d.c", "[abc].c")
    end

    test "a range matches its endpoints" do
      assert matches?("file0", "file[0-9]")
      assert matches?("file9", "file[0-9]")
      refute matches?("filea", "file[0-9]")
    end

    test "a set may be negated with ! or ^" do
      refute matches?("a.c", "[!abc].c")
      assert matches?("d.c", "[!abc].c")
      assert matches?("d.c", "[^abc].c")
    end

    test "a trailing dash is a literal dash" do
      assert matches?("a-b", "a[-]b")
    end

    test "an unterminated set is a literal bracket" do
      assert matches?("[abc", "[abc")
      refute matches?("a", "[abc")
    end
  end
end
