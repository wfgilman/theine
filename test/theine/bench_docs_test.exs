defmodule Theine.BenchDocsTest do
  # The Caffeine simulator cross-check (specs/09 §`mix bench hitrate` human
  # gate) is run by a person from bench/README.md and recorded in
  # IMPLEMENTATION_PLAN.md §Final gate. These check that both still name
  # every (trace, size) row of bench/traces.exs, so a size added to the
  # manifest cannot drop out of the human gate unnoticed.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp manifest_rows do
    {traces, _binding} = Code.eval_file(Path.join(@root, "bench/traces.exs"))

    for trace <- traces, size <- trace.sizes do
      format = %{arc: "arc", keys: "lirs"} |> Map.fetch!(trace.format)
      {trace.name, format, trace.file, size}
    end
  end

  defp section(file, heading, next_heading) do
    text = File.read!(Path.join(@root, file))
    [_, rest] = String.split(text, heading, parts: 2)
    [body | _] = String.split(rest, next_heading, parts: 2)
    body
  end

  defp readme_section do
    section("bench/README.md", "## Caffeine simulator cross-check", "\n## `maintenance`")
  end

  # Markdown table rows whose first two cells are a trace name and a size.
  defp table_rows(text) do
    for line <- String.split(text, "\n"),
        [_, trace, size | cells] <- [String.split(line, "|") |> Enum.map(&String.trim/1)],
        Regex.match?(~r/^\d+$/, size) do
      {trace, String.to_integer(size), cells}
    end
  end

  test "the simulator script runs every trace at every manifest size in its format" do
    [_, rows] = String.split(readme_section(), "<<'ROWS'\n", parts: 2)
    [rows | _] = String.split(rows, "\nROWS\n", parts: 2)

    script_rows =
      for line <- String.split(rows, "\n", trim: true) do
        [trace, format, file, size] = String.split(line)
        {trace, format, file, String.to_integer(size)}
      end

    assert script_rows == manifest_rows()
  end

  test "the self-check table and the final gate template have one row per manifest row" do
    expected = for {trace, _format, _file, size} <- manifest_rows(), do: {trace, size}

    self_check = table_rows(readme_section())

    template =
      section("IMPLEMENTATION_PLAN.md", "### Caffeine simulator cross-check", "\n## ")
      |> table_rows()

    assert for({trace, size, _} <- self_check, do: {trace, size}) == expected
    assert for({trace, size, _} <- template, do: {trace, size}) == expected

    # The template's lru column is the self-check's hit rate.
    lru_rates =
      for {trace, size, [_requests, _hits, rate | _]} <- self_check, do: {trace, size, rate}

    template_lru = for {trace, size, [lru | _]} <- template, do: {trace, size, lru}
    assert template_lru == lru_rates
  end
end
