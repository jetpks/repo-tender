# frozen_string_literal: true

require_relative "test_helper"
require "repo_tender/nav"

class CLINavTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  CLI = RepoTender::CLI
  Nav = RepoTender::Nav

  # Seed a temp base_dir with fake checkout dirs and inject it into the
  # CLI env so make_paths resolves correctly. Yields (env, home, base_dir).
  def with_nav_env(checkouts: [])
    with_temp_home do |env, home|
      base_dir = File.join(home, "src")
      FileUtils.mkdir_p(base_dir)
      checkouts.each do |path|
        FileUtils.mkdir_p(File.join(base_dir, path))
      end
      # Write a config.yaml pointing at base_dir
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      RepoTender::Config::Store.write(
        paths.config_file,
        RepoTender::Config::Config.new(
          base_dir: base_dir,
          refresh_interval: 21600,
          concurrency: 8,
          repos: [],
          orgs: []
        )
      )
      Thread.current[:repo_tender_cli_env] = env
      yield(env, home, base_dir)
    ensure
      Thread.current[:repo_tender_cli_env] = nil
    end
  end

  # ---- cd-contract: zero matches ----

  def test_no_match_writes_to_stderr_and_exits_1
    with_nav_env(checkouts: ["github.com/alice/myrepo"]) do |_env, _home, _base|
      stdout = StringIO.new
      stderr = StringIO.new
      assert_raises(SystemExit) do
        CLI.run(["zqxnomatch"], stdout, stderr)
      end.tap { |e| assert_equal 1, e.status }
      assert_includes stderr.string, "zqxnomatch"
      refute_match(%r{/}, stdout.string.strip)
    end
  end

  # ---- cd-contract: exactly one match ----

  def test_single_match_emits_abs_path_on_last_stdout_line_and_exits_0
    with_nav_env(checkouts: ["github.com/jetpks/space-architect"]) do |_env, home, base|
      stdout = StringIO.new
      stderr = StringIO.new
      exit_status = assert_raises(SystemExit) do
        CLI.run(["spaarc"], stdout, stderr)
      end
      assert_equal 0, exit_status.status
      last_line = stdout.string.strip.split("\n").last
      assert_equal File.join(base, "github.com", "jetpks", "space-architect"), last_line
    end
  end

  def test_single_match_stdout_last_line_is_the_path
    with_nav_env(checkouts: ["github.com/jetpks/space-architect"]) do |_env, home, base|
      stdout = StringIO.new
      stderr = StringIO.new
      assert_raises(SystemExit) { CLI.run(["jetspact"], stdout, stderr) }
      last_line = stdout.string.chomp.split("\n").last
      assert_equal File.join(base, "github.com", "jetpks", "space-architect"), last_line
    end
  end

  # ---- cd-contract: multiple matches ----

  def test_multiple_matches_stdout_has_candidates_and_exits_1
    with_nav_env(checkouts: [
      "github.com/jetpks/space-architect",
      "github.com/jetpks/space-cadet"
    ]) do
      stdout = StringIO.new
      stderr = StringIO.new
      exit_status = assert_raises(SystemExit) do
        CLI.run(["space"], stdout, stderr)
      end
      assert_equal 1, exit_status.status
      lines = stdout.string.strip.split("\n")
      assert lines.length >= 2, "multiple matches must produce multiple lines"
    end
  end

  def test_multiple_matches_no_lone_absolute_path_on_stdout
    with_nav_env(checkouts: [
      "github.com/jetpks/space-architect",
      "github.com/jetpks/space-cadet"
    ]) do |_env, home, base|
      stdout = StringIO.new
      stderr = StringIO.new
      assert_raises(SystemExit) { CLI.run(["space"], stdout, stderr) }
      # None of the stdout lines should be a standalone absolute path for one checkout
      lines = stdout.string.strip.split("\n")
      absolute_lines = lines.select { |l| l.start_with?("/") && File.directory?(l) }
      assert_empty absolute_lines, "multiple-match output must not contain a lone absolute path"
    end
  end

  # ---- routing: known commands dispatch to dry-cli ----

  def test_known_leaf_command_dispatches_to_dry_cli
    # "status" is a known leaf — must NOT be intercepted as bare query
    refute CLI.bare_query?(["status"]),
      "status must not be a bare query — it is a registered command"
  end

  def test_known_group_commands_not_bare_queries
    %w[repo org config daemon].each do |cmd|
      refute CLI.bare_query?([cmd]),
        "#{cmd} must not be a bare query — it is a registered group"
    end
  end

  def test_all_known_top_level_not_bare_queries
    %w[repo org sync status config daemon clone shell].each do |cmd|
      refute CLI.bare_query?([cmd]),
        "#{cmd} must not be a bare query"
    end
  end

  def test_unknown_single_token_is_bare_query
    assert CLI.bare_query?(["spaarc"])
    assert CLI.bare_query?(["zqxnomatch"])
    assert CLI.bare_query?(["jetspact"])
  end

  def test_multi_token_argv_is_not_bare_query
    refute CLI.bare_query?(["repo", "list"])
    refute CLI.bare_query?(["a", "b"])
  end

  def test_help_flags_not_bare_queries
    refute CLI.bare_query?(["--help"])
    refute CLI.bare_query?(["-h"])
    refute CLI.bare_query?(["help"])
  end

  def test_version_flags_not_bare_queries
    refute CLI.bare_query?(["version"])
    refute CLI.bare_query?(["--version"])
  end

  # ---- routing: multi-token and known commands flow to dry-cli (subprocess) ----

  def test_status_subprocess_routes_to_dry_cli
    with_nav_env do |env, _home, _base|
      _stdout, stderr, status = run_cli_subprocess(env: env, args: ["status"])
      assert status.success?, "status must exit 0; stderr=#{stderr}"
    end
  end

  # ---- bare-query seam: CLI.run vs the shared Nav dispatch ----

  def test_bare_query_uses_shared_seam
    with_nav_env(checkouts: ["github.com/alice/myrepo"]) do
      out = StringIO.new
      err = StringIO.new
      code = assert_raises(SystemExit) { CLI.run(["zqxnomatch"], out, err) }
      assert_equal 1, code.status
      assert_includes err.string, "zqxnomatch"
    end
  end

  def test_bare_query_single_match_returns_0_with_path
    with_nav_env(checkouts: ["github.com/alice/myrepo"]) do |_env, home, base|
      out = StringIO.new
      err = StringIO.new
      code = assert_raises(SystemExit) { CLI.run(["alice/myrepo"], out, err) }
      assert_equal 0, code.status
      last_line = out.string.chomp.split("\n").last
      assert_equal File.join(base, "github.com", "alice", "myrepo"), last_line
    end
  end
end
