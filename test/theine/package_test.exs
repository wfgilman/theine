defmodule Theine.PackageTest do
  # The hex package's contents and A6 (specs/00; specs/10 §Gates step 7).
  # `mix hex.build` itself runs in the final gate; these check the inputs it
  # reads, so a change to mix.exs or a stray native file fails the suite.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp config, do: Mix.Project.config()

  defp packaged_files do
    config()[:package][:files]
    |> Enum.flat_map(fn path ->
      full = Path.join(@root, path)
      if File.dir?(full), do: Path.wildcard(Path.join(full, "**/*")), else: [full]
    end)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, @root))
  end

  test "the package lists only lib, mix.exs, the README and the license" do
    files = config()[:package][:files]

    assert Enum.sort(files) == ["LICENSE", "README.md", "lib", "mix.exs"]
    assert Enum.all?(files, &File.exists?(Path.join(@root, &1)))
  end

  test "no bench, test, spec, priv or config file is packaged" do
    files = packaged_files()

    assert "lib/theine.ex" in files

    for file <- files do
      refute String.starts_with?(file, ["bench/", "test/", "specs/", "priv/", "config/"]),
             "#{file} would be packaged"
    end
  end

  test "the package metadata hex.build requires is present" do
    assert is_binary(config()[:description]) and config()[:description] != ""
    assert [_ | _] = config()[:package][:licenses]
    assert %{"GitHub" => "https://github.com/" <> _} = config()[:package][:links]
  end

  test "no packaged file is native code or a build script for it" do
    for file <- packaged_files() do
      refute Path.extname(file) in [".so", ".dll", ".dylib", ".c", ".h", ".cc", ".rs", ".zig"],
             "#{file} is native"

      refute Path.basename(file) in ["Makefile", "CMakeLists.txt", "Cargo.toml"],
             "#{file} is a native build script"
    end
  end

  test "mix.exs has no native compiler and telemetry is the only runtime dependency" do
    assert config()[:compilers] in [nil, Mix.compilers()]
    refute Keyword.has_key?(config(), :make_targets)

    runtime_deps =
      for {app, _req, opts} <- Enum.map(config()[:deps], &normalize_dep/1),
          opts[:only] == nil,
          do: app

    assert runtime_deps == [:telemetry]
  end

  test "lib loads no NIF and opens no port" do
    for file <- Path.wildcard(Path.join(@root, "lib/**/*.ex")) do
      source = File.read!(file)

      for marker <- ["load_nif", "@on_load", "open_port", "Port.open", "System.cmd"] do
        refute source =~ marker, "#{Path.relative_to(file, @root)} contains #{marker}"
      end
    end
  end

  defp normalize_dep({app, req}) when is_binary(req), do: {app, req, []}
  defp normalize_dep({app, opts}) when is_list(opts), do: {app, nil, opts}
  defp normalize_dep({app, req, opts}), do: {app, req, opts}
end
