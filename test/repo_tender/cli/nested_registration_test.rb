# frozen_string_literal: true

require_relative "test_helper"

# G7: nested subcommand registration works; the `repo` / `org` /
# `config` groups are directories (no leaf at the group level);
# unknown subcommands exit nonzero with usage to stderr.
#
# This file exists to centralize the Dry::CLI integration tests
# that exercise the registry directly (not just the per-command
# classes), so the per-command files (repo_test.rb, org_test.rb,
# etc.) can focus on the business logic of each subcommand.
class CLINestedRegistrationTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  PristineCLI = RepoTender::CLI

  # ---- G7 first: nested subcommand registration works ----

  def test_repo_add_dispatches_to_repo_add_command_subprocess
    with_cli_env do |env, _home|
      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["repo", "add", "github.com/x/y"])
      assert status.success?, "repo add should exit 0; got #{status.exitstatus}"
      assert_includes stdout, "added: github.com/x/y"
    end
  end

  def test_org_remove_dispatches_to_org_remove_command_subprocess
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      # Seed an org first.
      RepoTender::Config::Store.update(paths.config_file) do |c|
        RepoTender::Config::Store.with(c,
          orgs: [RepoTender::Config::OrgRef.new(host: "github.com", name: "socketry")])
      end
      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["org", "remove", "github.com/socketry"])
      assert status.success?, "org remove should exit 0; got #{status.exitstatus}"
      assert_includes stdout, "removed: github.com/socketry"
    end
  end

  def test_sync_dispatches_subprocess
    with_cli_env do |env, _home|
      # Empty config + no repos → engine returns success with empty state.
      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["sync"])
      assert status.success?, "sync should exit 0; got #{status.exitstatus}"
      assert_includes stdout, "synced 0 repo(s)"
    end
  end

  def test_status_dispatches_subprocess
    with_cli_env do |env, _home|
      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["status"])
      assert status.success?, "status should exit 0; got #{status.exitstatus}"
      assert_includes stdout, "no repos in state"
    end
  end

  # ---- G7 second: `repo` alone prints the group's usage ----
  # Per disagreement #5 in the PHASE-0 plan, we use dry-cli's
  # default (exit 1 + usage on stderr). The gate's "or" clause
  # accepts this.

  def test_repo_alone_prints_group_usage_to_stderr_and_exits_nonzero
    with_cli_env do |env, _home|
      _stdout, stderr, status = run_cli_subprocess(env: env, args: ["repo"])
      refute status.success?, "repo (no subcommand) should exit nonzero; got #{status.exitstatus}"
      # The usage banner lists each subcommand by name.
      assert_includes stderr, "repo add"
      assert_includes stderr, "repo remove"
      assert_includes stderr, "repo list"
    end
  end

  def test_org_alone_prints_group_usage_to_stderr_and_exits_nonzero
    with_cli_env do |env, _home|
      _stdout, stderr, status = run_cli_subprocess(env: env, args: ["org"])
      refute status.success?, "org (no subcommand) should exit nonzero; got #{status.exitstatus}"
      assert_includes stderr, "org add"
      assert_includes stderr, "org remove"
      assert_includes stderr, "org list"
    end
  end

  def test_config_alone_prints_group_usage_to_stderr_and_exits_nonzero
    with_cli_env do |env, _home|
      _stdout, stderr, status = run_cli_subprocess(env: env, args: ["config"])
      refute status.success?, "config (no subcommand) should exit nonzero; got #{status.exitstatus}"
      assert_includes stderr, "config path"
      assert_includes stderr, "config show"
    end
  end

  # ---- G7 third: unknown command → nonzero exit + usage/error ----

  def test_repo_frobnicate_exits_nonzero_with_usage
    with_cli_env do |env, _home|
      _stdout, stderr, status = run_cli_subprocess(env: env, args: ["repo", "frobnicate"])
      refute status.success?, "unknown subcommand should exit nonzero; got #{status.exitstatus}"
      # The usage banner is the error message.
      assert_includes stderr, "repo add"
      assert_includes stderr, "repo remove"
      assert_includes stderr, "repo list"
    end
  end

  def test_completely_unknown_command_exits_nonzero
    with_cli_env do |env, _home|
      _stdout, stderr, status = run_cli_subprocess(env: env, args: ["totally-unknown"])
      refute status.success?, "unknown command should exit nonzero; got #{status.exitstatus}"
      # Some kind of usage / error message.
      refute_empty stderr
    end
  end

  # ---- G0 executable sub-clause: top-level --help / version must
  #      exit 0 with output on STDOUT (a leaf like `sync --help`
  #      already does; the program-name level previously fell into
  #      Dry::CLI's no-leaf path → stderr + exit 1). Subprocess
  #      tests assert the real process exit status. ----

  def test_top_level_help_exits_zero_with_usage_on_stdout
    with_cli_env do |env, _home|
      stdout, stderr, status = run_cli_subprocess(env: env, args: ["--help"])
      assert status.success?, "top-level --help should exit 0; got #{status.exitstatus}"
      assert_empty stderr, "usage must go to stdout, not stderr"
      %w[repo org sync status config].each do |group|
        assert_includes stdout, group, "--help usage should list the #{group} group"
      end
    end
  end

  def test_top_level_dash_h_exits_zero_with_usage_on_stdout
    with_cli_env do |env, _home|
      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["-h"])
      assert status.success?, "top-level -h should exit 0; got #{status.exitstatus}"
      assert_includes stdout, "sync"
    end
  end

  def test_bare_invocation_exits_zero_with_usage_on_stdout
    with_cli_env do |env, _home|
      stdout, stderr, status = run_cli_subprocess(env: env, args: [])
      assert status.success?, "bare invocation should exit 0; got #{status.exitstatus}"
      assert_empty stderr
      assert_includes stdout, "status"
    end
  end

  def test_version_exits_zero_with_version_string
    with_cli_env do |env, _home|
      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["version"])
      assert status.success?, "version should exit 0; got #{status.exitstatus}"
      assert_includes stdout, RepoTender::VERSION
    end
  end

  def test_dash_dash_version_exits_zero_with_version_string
    with_cli_env do |env, _home|
      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["--version"])
      assert status.success?, "--version should exit 0; got #{status.exitstatus}"
      assert_includes stdout, RepoTender::VERSION
    end
  end
end
