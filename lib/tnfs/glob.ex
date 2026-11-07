defmodule Tnfs.Glob do
  @moduledoc """
  Minimal glob matcher for OPENDIRX patterns (handoff section 3.2).

  A pattern is compiled once per OPENDIRX and then matched against every
  candidate name. Matching is the iterative star-backtracking algorithm rather
  than plain recursion, so `*a*a*a*a*b` costs `O(name * pattern)` instead of
  blowing up exponentially: the pattern arrives from the network and must not
  be able to buy unbounded CPU time inside a session.

  Supported syntax is `*`, `?` and `[set]`, where a set may be negated with a
  leading `!` or `^` and may contain `a-z` ranges. Everything else is a literal
  byte, including an unterminated `[`. Names are opaque bytes, so case folding
  is ASCII-only; a client that wants exact bytes asks for a case-sensitive
  match. The REFERENCE glob is richer than this subset, which the README lists
  as a known limitation.
  """

  import Bitwise

  @type t :: %__MODULE__{}

  defstruct tokens: [], fold: true

  @doc """
  Compiles `pattern`. `fold` makes the match ASCII case-insensitive.

  An empty pattern compiles to a matcher that accepts only the empty name;
  callers that mean "no filter at all" pass `nil` around instead of compiling.
  """
  @spec compile(binary(), boolean()) :: t()
  def compile(pattern, fold) when is_binary(pattern) and is_boolean(fold) do
    %__MODULE__{tokens: parse(pattern, fold, []), fold: fold}
  end

  @doc "True when `name` matches the compiled pattern."
  @spec match?(t(), binary()) :: boolean()
  def match?(%__MODULE__{tokens: tokens, fold: fold}, name) when is_binary(name) do
    run(:binary.bin_to_list(if fold, do: fold(name), else: name), tokens, nil, nil)
  end

  # --- compilation -----------------------------------------------------------

  defp parse(<<>>, _fold, acc), do: Enum.reverse(acc)

  # Consecutive stars are the same token; collapsing them here keeps the
  # backtracking loop from revisiting identical states.
  defp parse(<<"*", rest::binary>>, fold, [:any | _] = acc), do: parse(rest, fold, acc)
  defp parse(<<"*", rest::binary>>, fold, acc), do: parse(rest, fold, [:any | acc])
  defp parse(<<"?", rest::binary>>, fold, acc), do: parse(rest, fold, [:one | acc])

  defp parse(<<"[", rest::binary>>, fold, acc) do
    case bracket(rest, fold) do
      {token, remaining} -> parse(remaining, fold, [token | acc])
      # Unterminated: the `[` was never a set, so it is an ordinary byte.
      :error -> parse(rest, fold, [?[ | acc])
    end
  end

  defp parse(<<byte, rest::binary>>, fold, acc) do
    parse(rest, fold, [if(fold, do: fold_byte(byte), else: byte) | acc])
  end

  defp bracket(<<"!", rest::binary>>, fold), do: members(rest, fold, true, [])
  defp bracket(<<"^", rest::binary>>, fold), do: members(rest, fold, true, [])
  defp bracket(rest, fold), do: members(rest, fold, false, [])

  defp members(<<>>, _fold, _negate, _acc), do: :error

  defp members(<<"]", rest::binary>>, _fold, negate, acc) do
    {{:set, negate, acc}, rest}
  end

  defp members(<<low, "-", high, rest::binary>>, fold, negate, acc) when high != ?] do
    members(rest, fold, negate, [{maybe_fold(low, fold), maybe_fold(high, fold)} | acc])
  end

  defp members(<<byte, rest::binary>>, fold, negate, acc) do
    members(rest, fold, negate, [maybe_fold(byte, fold) | acc])
  end

  defp maybe_fold(byte, true), do: fold_byte(byte)
  defp maybe_fold(byte, false), do: byte

  # --- matching --------------------------------------------------------------
  #
  # `star` is the position of the last `*` seen and `mark` the input position it
  # was first tried at. On a mismatch the loop rewinds to that star and lets it
  # swallow one more byte, which is what keeps the cost polynomial.

  # A star remembers where it was taken and then lets the match continue
  # greedily from there.
  defp run(input, [:any | tokens], _star, _mark), do: run(input, tokens, tokens, input)

  defp run([byte | input], [token | tokens], star, mark) do
    if single(token, byte), do: run(input, tokens, star, mark), else: retry(star, mark)
  end

  defp run([], [], _star, _mark), do: true

  defp run([], _tokens, star, mark), do: retry(star, mark)

  defp run(_input, [], star, mark), do: retry(star, mark)

  defp retry(nil, _mark), do: false

  defp retry(_star, []), do: false

  # The star swallows one more byte and the pattern restarts just after it.
  defp retry(star, [_swallowed | mark]), do: run(mark, star, star, mark)

  defp single(:one, _byte), do: true
  defp single({:set, negate, members}, byte), do: member?(members, byte) != negate
  defp single(literal, byte) when is_integer(literal), do: literal == byte

  defp member?(members, byte) do
    Enum.any?(members, fn
      {low, high} -> byte >= low and byte <= high
      literal -> literal == byte
    end)
  end

  # ASCII-only folding. A name is opaque bytes, so folding anything above 0x7f
  # would need an encoding the protocol does not promise.
  defp fold(name), do: for(<<byte <- name>>, into: <<>>, do: <<fold_byte(byte)>>)

  defp fold_byte(byte) when byte in ?A..?Z, do: byte ||| 0x20
  defp fold_byte(byte), do: byte
end
