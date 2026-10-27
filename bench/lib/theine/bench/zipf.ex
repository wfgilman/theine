defmodule Theine.Bench.Zipf do
  @moduledoc """
  Zipf-distributed integers in `1..n` with exponent `s`, by rejection-inversion
  (Hörmann and Derflinger, 1996; the same sampler Apache Commons and Caffeine's
  simulator use). Constant time per sample, no table over `n`, so a 1M-key
  generator costs nothing to build.

  The random state is explicit (`:rand` `exsss`), so a fixed seed always
  yields the same sequence. Rank 1 is the most frequent value.
  """

  @enforce_keys [:n, :s, :h_x1, :h_n, :threshold]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          n: pos_integer(),
          s: float(),
          h_x1: float(),
          h_n: float(),
          threshold: float()
        }

  @spec new(pos_integer(), number()) :: t()
  def new(n, s) when is_integer(n) and n >= 1 and is_number(s) and s > 0 do
    s = s / 1

    %__MODULE__{
      n: n,
      s: s,
      h_x1: h_integral(1.5, s) - 1.0,
      h_n: h_integral(n + 0.5, s),
      threshold: 2.0 - h_integral_inverse(h_integral(2.5, s) - h(2.0, s), s)
    }
  end

  @doc "Seeds a `:rand` state for `sample/2`."
  @spec seed(integer()) :: :rand.state()
  def seed(seed) when is_integer(seed), do: :rand.seed_s(:exsss, {seed, seed * 7 + 1, 2026})

  @doc "Draws one value in `1..n`."
  @spec sample(t(), :rand.state()) :: {pos_integer(), :rand.state()}
  def sample(%__MODULE__{} = z, rand) do
    {u0, rand} = :rand.uniform_s(rand)
    u = z.h_n + u0 * (z.h_x1 - z.h_n)
    x = h_integral_inverse(u, z.s)
    k = (x + 0.5) |> trunc() |> max(1) |> min(z.n)

    if k - x <= z.threshold or u >= h_integral(k + 0.5, z.s) - h(k, z.s) do
      {k, rand}
    else
      sample(z, rand)
    end
  end

  @doc "Draws `count` values from a fresh state seeded with `seed`, as a list."
  @spec take(t(), non_neg_integer(), integer()) :: [pos_integer()]
  def take(%__MODULE__{} = z, count, seed) when is_integer(count) and count >= 0 do
    {values, _rand} =
      Enum.map_reduce(1..count//1, seed(seed), fn _, rand -> sample(z, rand) end)

    values
  end

  defp h(x, s), do: :math.exp(-s * :math.log(x))

  defp h_integral(x, s) do
    log_x = :math.log(x)
    helper2((1.0 - s) * log_x) * log_x
  end

  defp h_integral_inverse(x, s) do
    t = x * (1.0 - s)
    # t <= -1 means exp(-inf) in the reference; :math.log(0.0) would raise.
    if t <= -1.0, do: 0.0, else: :math.exp(helper1(t) * x)
  end

  # log1p(x) / x, with the series near zero where the quotient is 0/0.
  defp helper1(x) when abs(x) > 1.0e-8, do: :math.log(1.0 + x) / x
  defp helper1(x), do: 1.0 - x * (0.5 - x * (1.0 / 3.0 - 0.25 * x))

  # expm1(x) / x, likewise.
  defp helper2(x) when abs(x) > 1.0e-8, do: (:math.exp(x) - 1.0) / x
  defp helper2(x), do: 1.0 + x * 0.5 * (1.0 + x / 3.0 * (1.0 + 0.25 * x))
end
