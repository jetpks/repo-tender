# frozen_string_literal: true

require_relative "test_helper"
require "repo_tender/cli/shell"
require "tmpdir"
require "fileutils"

class SrcShellFishTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  CLI = RepoTender::CLI
  ShellIntegration = RepoTender::ShellIntegration

  # ---- shell fish install ----

  def test_fish_install_writes_both_files
    with_cli_env do |env, home|
      out, _err = invoke_command(CLI::Shell::Fish, subcommand: "install", force: false)
      assert_equal 0, CLI.last_outcome.exit_code
      fn_path = ShellIntegration.path_for("fish", env: env)
      co_path = ShellIntegration.completions_path_for("fish", env: env)
      assert File.exist?(fn_path), "function file must exist"
      assert File.exist?(co_path), "completions file must exist"
      assert fn_path.to_s.start_with?(home), "must be under temp home"
      assert out.string.include?("fish"), "output must mention fish"
    end
  end

  def test_fish_install_is_idempotent
    with_cli_env do
      invoke_command(CLI::Shell::Fish, subcommand: "install", force: false)
      out, _err = invoke_command(CLI::Shell::Fish, subcommand: "install", force: false)
      assert_equal 0, CLI.last_outcome.exit_code
      assert_includes out.string, "already installed"
    end
  end

  def test_fish_install_default_subcommand
    with_cli_env do |env, _home|
      _out, _err = invoke_command(CLI::Shell::Fish)
      assert_equal 0, CLI.last_outcome.exit_code
      fn_path = ShellIntegration.path_for("fish", env: env)
      assert File.exist?(fn_path)
    end
  end

  # ---- shell fish uninstall ----

  def test_fish_uninstall_removes_both_files
    with_cli_env do |env, _home|
      ShellIntegration.install("fish", env: env, force: false)
      fn_path = ShellIntegration.path_for("fish", env: env)
      co_path = ShellIntegration.completions_path_for("fish", env: env)

      out, _err = invoke_command(CLI::Shell::Fish, subcommand: "uninstall", force: false)
      assert_equal 0, CLI.last_outcome.exit_code
      refute File.exist?(fn_path)
      refute File.exist?(co_path)
      assert_includes out.string, "Removed"
    end
  end

  def test_fish_uninstall_missing_reports_not_installed
    with_cli_env do
      out, _err = invoke_command(CLI::Shell::Fish, subcommand: "uninstall", force: false)
      assert_equal 0, CLI.last_outcome.exit_code
      assert_includes out.string, "not installed"
    end
  end

  # ---- shell fish path ----

  def test_fish_path_prints_both_paths
    with_cli_env do |env, home|
      out, _err = invoke_command(CLI::Shell::Fish, subcommand: "path")
      assert_equal 0, CLI.last_outcome.exit_code
      assert_includes out.string, "Function:"
      assert_includes out.string, "Completions:"
      assert_includes out.string, home
    end
  end

  # ---- shell fish unknown subcommand ----

  def test_fish_unknown_subcommand_exits_1
    with_cli_env do
      _out, err = invoke_command(CLI::Shell::Fish, subcommand: "bogus")
      assert_equal 1, CLI.last_outcome.exit_code
      assert_includes err.string, "Usage:"
    end
  end

  # ---- shell complete checkouts ----

  def test_complete_checkouts_lists_checkout_names
    with_cli_env do |env, home|
      base_dir = File.join(home, "src")
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "acme", "myrepo"))
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "acme", "other"))

      # Write a config that points at our temp base_dir
      paths = RepoTender::Paths.new(environment: env)
      FileUtils.mkdir_p(paths.config_dir)
      File.write(paths.config_file, "base_dir: #{base_dir}\n")

      out, _err = invoke_command(CLI::Shell::Complete, kind: "checkouts")
      assert_equal 0, CLI.last_outcome.exit_code
      names = out.string.lines.map(&:chomp).reject(&:empty?)
      assert_includes names, "acme/myrepo"
      assert_includes names, "acme/other"
    end
  end

  def test_complete_checkouts_tolerates_missing_config
    with_cli_env do
      _out, _err = invoke_command(CLI::Shell::Complete, kind: "checkouts")
      assert_equal 0, CLI.last_outcome.exit_code
      # No crash; empty or default output is fine
    end
  end

  # ---- shell complete shells ----

  def test_complete_shells_returns_fish
    with_cli_env do
      out, _err = invoke_command(CLI::Shell::Complete, kind: "shells")
      assert_equal 0, CLI.last_outcome.exit_code
      assert_includes out.string, "fish"
    end
  end

  # ---- shell complete unknown kind ----

  def test_complete_unknown_kind_exits_1
    with_cli_env do
      _out, err = invoke_command(CLI::Shell::Complete, kind: "bogus-kind")
      assert_equal 1, CLI.last_outcome.exit_code
      assert_includes err.string, "Usage:"
    end
  end

  # ---- fish and complete are registered ----

  def test_fish_is_registered_under_shell
    shell_node = CLI::Registry.get(["shell"])
    assert shell_node.children.key?("fish"),
      "fish must be registered under shell"
  end

  def test_complete_is_registered_under_shell
    shell_node = CLI::Registry.get(["shell"])
    assert shell_node.children.key?("complete"),
      "complete must be registered under shell"
  end
end
