# frozen_string_literal: true

require_relative "test_helper"

class CLIRepoTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  PristineCLI = RepoTender::CLI

  # ---- G1: repo CRUD persists to validated config.yaml ----

  def test_repo_add_persists_validated_entry
    with_cli_env do |env, _home|
      out, _err = invoke_command(PristineCLI::Repo::Add, ref: "github.com/ruby/ruby")
      assert_equal "added: github.com/ruby/ruby\n", out.string
      assert_equal 0, PristineCLI.last_outcome.exit_code

      paths = RepoTender::Paths.new(environment: env)
      cfg = RepoTender::Config::Store.load(paths.config_file).success
      assert_equal 1, cfg.repos.size
      assert_equal "ruby", cfg.repos.first.owner
      assert_equal "ruby", cfg.repos.first.name
      assert_equal "github.com", cfg.repos.first.host
    end
  end

  def test_repo_list_prints_tracked_repos
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      RepoTender::Config::Store.write(paths.config_file,
        RepoTender::Config::Store.load(paths.config_file).success.new(
          repos: [RepoTender::Config::RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")]
        ))

      out, _err = invoke_command(PristineCLI::Repo::List)
      assert_equal "github.com/ruby/ruby\n", out.string
      assert_equal 0, PristineCLI.last_outcome.exit_code
    end
  end

  def test_repo_remove_deletes_entry
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      # Seed with a repo via the store.
      RepoTender::Config::Store.update(paths.config_file) do |c|
        RepoTender::Config::Store.with(c,
          repos: [RepoTender::Config::RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")])
      end

      out, _err = invoke_command(PristineCLI::Repo::Remove, ref: "github.com/ruby/ruby")
      assert_equal "removed: github.com/ruby/ruby\n", out.string
      assert_equal 0, PristineCLI.last_outcome.exit_code

      cfg = RepoTender::Config::Store.load(paths.config_file).success
      assert_empty cfg.repos
    end
  end

  def test_repo_add_idempotent_does_not_duplicate
    with_cli_env do |env, _home|
      # Add once.
      invoke_command(PristineCLI::Repo::Add, ref: "github.com/ruby/ruby")
      assert_equal 0, PristineCLI.last_outcome.exit_code
      # Add again with the same ref.
      out, _err = invoke_command(PristineCLI::Repo::Add, ref: "github.com/ruby/ruby")
      assert_equal "already tracked: github.com/ruby/ruby\n", out.string
      assert_equal 0, PristineCLI.last_outcome.exit_code

      paths = RepoTender::Paths.new(environment: env)
      cfg = RepoTender::Config::Store.load(paths.config_file).success
      assert_equal 1, cfg.repos.size, "duplicate add must not write a second entry"
    end
  end

  # ---- G3: invalid input → nonzero exit + Failure-derived stderr
  #        + config byte-for-byte unchanged ----

  def test_repo_add_invalid_ref_exits_nonzero_with_stderr_message
    with_cli_env do |env, home|
      paths = RepoTender::Paths.new(environment: env)
      # Pre-create a config file with known bytes + mtime.
      FileUtils.mkdir_p(paths.config_dir)
      File.write(paths.config_file, "base_dir: /tmp/evergreen\nrefresh_interval: 7200\n")
      mtime_before = File.mtime(paths.config_file)
      bytes_before = File.read(paths.config_file)

      out, err = invoke_command(PristineCLI::Repo::Add, ref: "not-a-ref")
      assert_equal 1, PristineCLI.last_outcome.exit_code
      assert_includes err.string, "invalid repo reference"
      assert_includes err.string, "\"not-a-ref\""
      assert_equal "", out.string, "no stdout on Failure"

      # Config file is byte-for-byte unchanged.
      assert_equal bytes_before, File.read(paths.config_file)
      assert_equal mtime_before, File.mtime(paths.config_file),
        "config file mtime changed on a rejected add (store was touched)"
    end
  end

  def test_repo_add_invalid_ref_does_not_create_config_file
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      refute File.exist?(paths.config_file), "precondition: no config file"

      _, err = invoke_command(PristineCLI::Repo::Add, ref: "garbage")
      assert_equal 1, PristineCLI.last_outcome.exit_code
      assert_includes err.string, "invalid repo reference"

      refute File.exist?(paths.config_file),
        "a rejected add must not create the config file"
    end
  end

  # Same in-process failure translated to a real subprocess exit code
  # (the G3 "real exit" proof).
  def test_repo_add_invalid_ref_subprocess_exits_nonzero
    with_cli_env do |env, _home|
      _, stderr, status = run_cli_subprocess(env: env, args: ["repo", "add", "not-a-ref"])
      refute status.success?, "subprocess should exit nonzero; got #{status.exitstatus}"
      assert_includes stderr, "invalid repo reference"
    end
  end

  def test_repo_add_subprocess_succeeds
    with_cli_env do |env, _home|
      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["repo", "add", "github.com/foo/bar"])
      assert status.success?, "subprocess should exit 0; got #{status.exitstatus}"
      assert_includes stdout, "added: github.com/foo/bar"

      paths = RepoTender::Paths.new(environment: env)
      cfg = RepoTender::Config::Store.load(paths.config_file).success
      assert_equal 1, cfg.repos.size
    end
  end

  # ---- RC1/RC3: color in pretty mode, no color otherwise ----

  def test_repo_add_has_color_in_pretty_mode
    with_cli_env do |_env, _home|
      tty_out = Class.new(StringIO) { def tty? = true }.new
      cmd = PristineCLI::Repo::Add.new
      cmd.instance_variable_set(:@out, tty_out)
      cmd.instance_variable_set(:@err, StringIO.new)
      cmd.call(ref: "github.com/ruby/ruby", plain: nil, json: nil, no_color: nil, quiet: nil)
      assert_match(/\e\[[0-9;]*m/, tty_out.string)
    end
  end

  def test_repo_add_no_color_with_no_color_flag
    with_cli_env do |_env, _home|
      tty_out = Class.new(StringIO) { def tty? = true }.new
      cmd = PristineCLI::Repo::Add.new
      cmd.instance_variable_set(:@out, tty_out)
      cmd.instance_variable_set(:@err, StringIO.new)
      cmd.call(ref: "github.com/ruby/ruby", plain: nil, json: nil, no_color: true, quiet: nil)
      refute_match(/\e\[[0-9;]*m/, tty_out.string)
    end
  end

  def test_repo_add_no_color_with_no_color_env
    with_cli_env do |env, _home|
      Thread.current[:repo_tender_cli_env] = env.merge("NO_COLOR" => "1")
      tty_out = Class.new(StringIO) { def tty? = true }.new
      cmd = PristineCLI::Repo::Add.new
      cmd.instance_variable_set(:@out, tty_out)
      cmd.instance_variable_set(:@err, StringIO.new)
      cmd.call(ref: "github.com/ruby/ruby", plain: nil, json: nil, no_color: nil, quiet: nil)
      refute_match(/\e\[[0-9;]*m/, tty_out.string)
    end
  end

  def test_repo_list_has_color_in_pretty_mode
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      RepoTender::Config::Store.write(paths.config_file,
        RepoTender::Config::Store.load(paths.config_file).success.new(
          repos: [RepoTender::Config::RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")]
        ))
      tty_out = Class.new(StringIO) { def tty? = true }.new
      cmd = PristineCLI::Repo::List.new
      cmd.instance_variable_set(:@out, tty_out)
      cmd.instance_variable_set(:@err, StringIO.new)
      cmd.call(plain: nil, json: nil, no_color: nil, quiet: nil)
      assert_match(/\e\[[0-9;]*m/, tty_out.string)
    end
  end

  def test_repo_list_no_color_in_non_tty
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      RepoTender::Config::Store.write(paths.config_file,
        RepoTender::Config::Store.load(paths.config_file).success.new(
          repos: [RepoTender::Config::RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")]
        ))
      out, _err = invoke_command(PristineCLI::Repo::List)
      refute_match(/\e\[[0-9;]*m/, out.string)
    end
  end
end
