defmodule Theine.Bench.Report do
  @moduledoc """
  Shared plumbing for the `bench/*.exs` scripts: the run environment, the
  ERL_FLAGS check, the JSON result file and markdown tables (specs/09
  §Reference machine). The envelope written here is documented in
  `bench/README.md`; keep the two in step.
  """

  @schema_version 1
  @results_dir "bench/results"
  @wanted_flags ["+sbt db", "+sbwt very_long"]

  @doc "Short git sha of HEAD, or \"nogit\" outside a work tree."
  @spec git_sha() :: String.t()
  def git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "nogit"
    end
  end

  @spec git_dirty?() :: boolean()
  def git_dirty? do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> false
      _ -> true
    end
  end

  @doc """
  Warns on stderr when ERL_FLAGS lacks the scheduler flags specs/09 asks for.
  Returns the flags that are missing.
  """
  @spec check_erl_flags() :: [String.t()]
  def check_erl_flags do
    flags = System.get_env("ERL_FLAGS", "")
    missing = Enum.reject(@wanted_flags, &String.contains?(flags, &1))

    if missing != [] do
      IO.puts(
        :stderr,
        "warning: ERL_FLAGS lacks #{Enum.join(missing, " and ")}; numbers will be noisier. " <>
          ~s(Run with ERL_FLAGS="#{Enum.join(@wanted_flags, " ")}" mix bench ...)
      )
    end

    missing
  end

  @doc "The `system` object of the result envelope."
  @spec system(map()) :: map()
  def system(extra \\ %{}) do
    Map.merge(
      %{
        otp: System.otp_release(),
        elixir: System.version(),
        schedulers_online: System.schedulers_online(),
        erl_flags: System.get_env("ERL_FLAGS", ""),
        scheduler_bind_type: inspect(:erlang.system_info(:scheduler_bind_type))
      },
      extra
    )
  end

  @doc """
  Writes `bench/results/<bench>-<sha>.json` and returns its path. `body` holds
  the bench-specific `results` and `thresholds`; the envelope fields are added
  here and `passed` is derived from the thresholds.
  """
  @spec write_json(String.t(), map()) :: Path.t()
  def write_json(bench, %{results: _, thresholds: thresholds} = body) do
    sha = git_sha()

    envelope =
      Map.merge(body, %{
        bench: bench,
        schema_version: @schema_version,
        git_sha: sha,
        git_dirty: git_dirty?(),
        timestamp: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        passed: Enum.all?(thresholds, & &1.passed)
      })

    File.mkdir_p!(@results_dir)
    path = Path.join(@results_dir, "#{bench}-#{sha}.json")
    File.write!(path, JSON.encode!(envelope))
    path
  end

  @doc "Renders a markdown table from a header row and rows of cells."
  @spec table([String.t()], [[term()]]) :: String.t()
  def table(header, rows) do
    lines = [
      row(header),
      row(Enum.map(header, fn _ -> "---" end))
      | Enum.map(rows, fn cells -> row(Enum.map(cells, &cell/1)) end)
    ]

    Enum.join(lines, "\n")
  end

  defp row(cells), do: "| " <> Enum.join(cells, " | ") <> " |"

  defp cell(nil), do: ""
  defp cell(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 2)
  defp cell(other), do: to_string(other)

  @doc "Renders the threshold section of a summary."
  @spec thresholds_markdown([map()], String.t()) :: String.t()
  def thresholds_markdown([], none_message), do: "Thresholds: " <> none_message

  def thresholds_markdown(thresholds, _none_message) do
    failed = Enum.reject(thresholds, & &1.passed)

    header =
      "Thresholds: #{length(thresholds) - length(failed)}/#{length(thresholds)} passed"

    if failed == [] do
      header
    else
      rows =
        Enum.map(failed, fn t -> [t.id, t.description, t.actual, t.limit] end)

      header <> "\n\nFailed:\n\n" <> table(["id", "check", "actual", "limit"], rows)
    end
  end
end
