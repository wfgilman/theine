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

  @doc """
  The `system` object of the result envelope. `cpu_model` and `os` with
  `otp` and `schedulers_online` are the machine record the final gate
  keeps with each run (specs/09 §Reference machine).
  """
  @spec system(map()) :: map()
  def system(extra \\ %{}) do
    Map.merge(
      %{
        otp: System.otp_release(),
        elixir: System.version(),
        schedulers_online: System.schedulers_online(),
        erl_flags: System.get_env("ERL_FLAGS", ""),
        scheduler_bind_type: inspect(:erlang.system_info(:scheduler_bind_type)),
        cpu_model: cpu_model(),
        os: os()
      },
      extra
    )
  end

  # Linux names the CPU in /proc/cpuinfo, macOS through sysctl (an Apple
  # chip has no `machdep.cpu.brand_string` on older releases, hence the
  # fallback to the architecture string).
  defp cpu_model do
    with {:ok, info} <- File.read("/proc/cpuinfo"),
         [_, model] <- Regex.run(~r/^model name\s*:\s*(.+)$/m, info) do
      String.trim(model)
    else
      _ ->
        case cmd("sysctl", ["-n", "machdep.cpu.brand_string"]) do
          {:ok, model} -> model
          :error -> to_string(:erlang.system_info(:system_architecture))
        end
    end
  end

  # `uname -sr` (e.g. "Linux 6.8.0", "Darwin 24.1.0"), plus the product
  # version on macOS, since the Darwin release does not name it.
  defp os do
    base =
      case cmd("uname", ["-sr"]) do
        {:ok, uname} -> uname
        :error -> inspect(:os.type())
      end

    case cmd("sw_vers", ["-productVersion"]) do
      {:ok, version} -> "#{base} (macOS #{version})"
      :error -> base
    end
  end

  defp cmd(command, args) do
    with path when is_binary(path) <- System.find_executable(command),
         {out, 0} <- System.cmd(path, args, stderr_to_stdout: true) do
      {:ok, String.trim(out)}
    else
      _ -> :error
    end
  end

  @doc """
  Writes `bench/results/<bench>-<sha>.json`, or `<bench>-<sha>-<label>.json`
  with a label, and returns its path. `body` holds the bench-specific
  `results` and `thresholds`; the envelope fields are added here and
  `passed` is derived from the thresholds.
  """
  @spec write_json(String.t(), map(), String.t() | nil) :: Path.t()
  def write_json(bench, %{results: _, thresholds: thresholds} = body, label \\ nil) do
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
    file = if label, do: "#{bench}-#{sha}-#{label}.json", else: "#{bench}-#{sha}.json"
    path = Path.join(@results_dir, file)
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
