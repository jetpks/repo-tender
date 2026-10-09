# frozen_string_literal: true

require_relative "test_helper"

class CLIStatusTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  PristineCLI = RepoTender::CLI

  # ---- G5: `status` renders a per-repo evergreen table ----

  def test_status_renders_per_repo_evergreen_table
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!

      # Seed state with 2 repos of differing status.
      seeded = RepoTender::State::Store::State.new(
        repos: {
          "github.com/ruby/ruby" => RepoTender::State::Store::Repo.new(
            default_branch: "trunk",
            last_fetch_at: "2026-06-12T20:01:33Z",
            last_synced_at: "2026-06-12T20:01:34Z",
            status: "clean",
            last_error: nil
          ),
          "github.com/other/repo" => RepoTender::State::Store::Repo.new(
            default_branch: "main",
            last_fetch_at: "2026-06-12T19:00:00Z",
            last_synced_at: "2026-06-12T19:00:01Z",
            status: "dirty",
            last_error: nil
          )
        },
        orgs: {}
      )
      RepoTender::State::Store.write(paths.state_file, seeded)

      out, _err = invoke_command(PristineCLI::Status::Show)
      assert_equal 0, PristineCLI.last_outcome.exit_code

      # G5 assertion: stdout contains each repo key and its status.
      assert_includes out.string, "github.com/ruby/ruby"
      assert_includes out.string, "github.com/other/repo"
      assert_includes out.string, "clean"
      assert_includes out.string, "dirty"
      assert_includes out.string, "trunk"
      assert_includes out.string, "main"
      assert_includes out.string, "2026-06-12T20:01:34Z"
    end
  end

  def test_status_with_empty_state_prints_friendly_message
    with_cli_env do |_env, _home|
      out, _err = invoke_command(PristineCLI::Status::Show)
      assert_equal 0, PristineCLI.last_outcome.exit_code
      assert_includes out.string, "no repos in state"
    end
  end

  def test_status_subprocess_prints_table
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      seeded = RepoTender::State::Store::State.new(
        repos: {
          "github.com/x/y" => RepoTender::State::Store::Repo.new(
            default_branch: "trunk",
            last_fetch_at: "2026-06-12T20:01:33Z",
            last_synced_at: "2026-06-12T20:01:34Z",
            status: "clean",
            last_error: nil
          )
        },
        orgs: {}
      )
      RepoTender::State::Store.write(paths.state_file, seeded)

      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["status"])
      assert status.success?, "status subprocess should exit 0; got #{status.exitstatus}"
      assert_includes stdout, "github.com/x/y"
      assert_includes stdout, "clean"
      assert_includes stdout, "trunk"
    end
  end

  # ---- RC1/RC2/RC3: color in pretty mode, byte-equal content ----

  def seed_status_state(paths)
    RepoTender::State::Store.write(paths.state_file,
      RepoTender::State::Store::State.new(
        repos: {
          "github.com/ruby/ruby" => RepoTender::State::Store::Repo.new(
            default_branch: "trunk",
            last_fetch_at: "2026-06-12T20:01:33Z",
            last_synced_at: "2026-06-12T20:01:34Z",
            status: "clean",
            last_error: nil
          )
        },
        orgs: {}
      ))
  end

  def test_status_color_in_pretty_mode
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      seed_status_state(paths)

      tty_out = Class.new(StringIO) { def tty? = true }.new
      cmd = PristineCLI::Status::Show.new
      cmd.instance_variable_set(:@out, tty_out)
      cmd.instance_variable_set(:@err, StringIO.new)
      cmd.call(plain: nil, json: nil, no_color: nil, quiet: nil)
      assert_match(/\e\[[0-9;]*m/, tty_out.string)
    end
  end

  def test_status_byte_identical_in_plain
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      seed_status_state(paths)

      # :plain output (non-TTY StringIO)
      out_plain, _err = invoke_command(PristineCLI::Status::Show)
      plain_str = out_plain.string

      # :pretty output (TTY)
      tty_out = Class.new(StringIO) { def tty? = true }.new
      cmd = PristineCLI::Status::Show.new
      cmd.instance_variable_set(:@out, tty_out)
      cmd.instance_variable_set(:@err, StringIO.new)
      cmd.call(plain: nil, json: nil, no_color: nil, quiet: nil)
      pretty_str = tty_out.string

      assert_match(/\e\[[0-9;]*m/, pretty_str, "pretty mode must have SGR codes")
      assert_equal plain_str, pretty_str.gsub(/\e\[[0-9;]*m/, ""),
        "stripping SGR from pretty must produce byte-identical plain output"
    end
  end

  def test_status_no_color_with_no_color_flag
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      seed_status_state(paths)

      tty_out = Class.new(StringIO) { def tty? = true }.new
      cmd = PristineCLI::Status::Show.new
      cmd.instance_variable_set(:@out, tty_out)
      cmd.instance_variable_set(:@err, StringIO.new)
      cmd.call(plain: nil, json: nil, no_color: true, quiet: nil)
      refute_match(/\e\[[0-9;]*m/, tty_out.string)
    end
  end
end
