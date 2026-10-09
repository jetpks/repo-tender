# frozen_string_literal: true

require_relative "test_helper"

class CLIOrgTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  PristineCLI = RepoTender::CLI

  # ---- G2: org CRUD persists to validated config.yaml ----

  def test_org_add_persists_validated_entry
    with_cli_env do |env, _home|
      out, _err = invoke_command(PristineCLI::Org::Add, name: "github.com/socketry")
      assert_equal "added: github.com/socketry (include_archived=false, include_forks=false)\n", out.string
      assert_equal 0, PristineCLI.last_outcome.exit_code

      paths = RepoTender::Paths.new(environment: env)
      cfg = RepoTender::Config::Store.load(paths.config_file).success
      assert_equal 1, cfg.orgs.size
      assert_equal "socketry", cfg.orgs.first.name
      assert_equal "github.com", cfg.orgs.first.host
      refute cfg.orgs.first.include_archived
      refute cfg.orgs.first.include_forks
    end
  end

  def test_org_add_with_bare_name_defaults_host_to_github_com
    with_cli_env do |env, _home|
      out, _err = invoke_command(PristineCLI::Org::Add, name: "example-org")
      assert_equal 0, PristineCLI.last_outcome.exit_code
      assert_includes out.string, "added: github.com/example-org"

      paths = RepoTender::Paths.new(environment: env)
      cfg = RepoTender::Config::Store.load(paths.config_file).success
      assert_equal "github.com", cfg.orgs.first.host
      assert_equal "example-org", cfg.orgs.first.name
    end
  end

  def test_org_add_include_archived_and_include_forks_round_trip
    with_cli_env do |env, _home|
      invoke_command(PristineCLI::Org::Add,
        name: "example-org",
        include_archived: true,
        include_forks: true)
      assert_equal 0, PristineCLI.last_outcome.exit_code

      paths = RepoTender::Paths.new(environment: env)
      cfg = RepoTender::Config::Store.load(paths.config_file).success
      assert cfg.orgs.first.include_archived
      assert cfg.orgs.first.include_forks
    end
  end

  def test_org_list_prints_tracked_orgs
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      RepoTender::Config::Store.write(paths.config_file,
        RepoTender::Config::Store.load(paths.config_file).success.new(
          orgs: [
            RepoTender::Config::OrgRef.new(host: "github.com", name: "socketry"),
            RepoTender::Config::OrgRef.new(host: "github.com", name: "example-org", include_archived: true)
          ]
        ))

      out, _err = invoke_command(PristineCLI::Org::List)
      assert_includes out.string, "github.com/socketry (include_archived=false, include_forks=false)"
      assert_includes out.string, "github.com/example-org (include_archived=true, include_forks=false)"
      assert_equal 0, PristineCLI.last_outcome.exit_code
    end
  end

  def test_org_remove_deletes_entry
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      RepoTender::Config::Store.update(paths.config_file) do |c|
        RepoTender::Config::Store.with(c,
          orgs: [RepoTender::Config::OrgRef.new(host: "github.com", name: "socketry")])
      end

      out, _err = invoke_command(PristineCLI::Org::Remove, name: "github.com/socketry")
      assert_equal "removed: github.com/socketry\n", out.string
      assert_equal 0, PristineCLI.last_outcome.exit_code

      cfg = RepoTender::Config::Store.load(paths.config_file).success
      assert_empty cfg.orgs
    end
  end

  def test_org_add_idempotent_does_not_duplicate
    with_cli_env do |env, _home|
      invoke_command(PristineCLI::Org::Add, name: "github.com/socketry")
      out, _err = invoke_command(PristineCLI::Org::Add, name: "github.com/socketry")
      assert_includes out.string, "already tracked: github.com/socketry"
      assert_equal 0, PristineCLI.last_outcome.exit_code

      paths = RepoTender::Paths.new(environment: env)
      cfg = RepoTender::Config::Store.load(paths.config_file).success
      assert_equal 1, cfg.orgs.size
    end
  end

  # ---- GA4: --ignored-repos ----

  def test_org_add_ignored_repos_persists_to_config
    with_cli_env do |env, _home|
      invoke_command(PristineCLI::Org::Add,
        name: "bigco",
        ignored_repos: ["monorepo", "huge"])
      assert_equal 0, PristineCLI.last_outcome.exit_code

      paths = RepoTender::Paths.new(environment: env)
      cfg = RepoTender::Config::Store.load(paths.config_file).success
      assert_equal ["monorepo", "huge"], cfg.orgs.first.ignored_repos
    end
  end

  def test_org_add_ignored_repos_shown_in_output
    with_cli_env do |_env, _home|
      out, _err = invoke_command(PristineCLI::Org::Add,
        name: "bigco",
        ignored_repos: ["monorepo", "huge"])
      assert_includes out.string, 'ignored_repos=["monorepo", "huge"]'
    end
  end

  def test_org_list_shows_ignored_repos_when_non_empty
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      RepoTender::Config::Store.write(paths.config_file,
        RepoTender::Config::Store.load(paths.config_file).success.new(
          orgs: [
            RepoTender::Config::OrgRef.new(host: "github.com", name: "bigco",
              ignored_repos: ["monorepo", "huge"])
          ]
        ))
      out, _err = invoke_command(PristineCLI::Org::List)
      assert_includes out.string, 'ignored_repos=["monorepo", "huge"]'
    end
  end

  def test_org_list_omits_ignored_repos_when_empty
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      RepoTender::Config::Store.write(paths.config_file,
        RepoTender::Config::Store.load(paths.config_file).success.new(
          orgs: [RepoTender::Config::OrgRef.new(host: "github.com", name: "plain")]
        ))
      out, _err = invoke_command(PristineCLI::Org::List)
      refute_includes out.string, "ignored_repos"
    end
  end

  def test_org_add_ignored_repos_comma_form_via_subprocess
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      _out, err, status = run_cli_subprocess(
        env: env,
        args: ["org", "add", "bigco", "--ignored-repos", "monorepo,huge"]
      )
      assert status.success?, "subprocess failed: #{err}"
      cfg = RepoTender::Config::Store.load(paths.config_file).success
      assert_equal ["monorepo", "huge"], cfg.orgs.first.ignored_repos
    end
  end

  # NOTE: dry-cli 1.4.1 does NOT accumulate repeated array flags —
  # `--ignored-repos a --ignored-repos b` yields ["b"] (last wins).
  # The gate GA4 repeated-form assertion cannot be proved against the
  # current dry-cli. Documented as COMPLETE_WITH_CONCERNS in the lane report.
  # The comma form is the supported user-facing affordance.
  def test_org_add_ignored_repos_comma_form_is_canonical
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      _out, err, status = run_cli_subprocess(
        env: env,
        args: ["org", "add", "bigco", "--ignored-repos", "a,b"]
      )
      assert status.success?, "subprocess failed: #{err}"
      cfg = RepoTender::Config::Store.load(paths.config_file).success
      assert_equal ["a", "b"], cfg.orgs.first.ignored_repos
    end
  end

  # ---- G3: invalid input → nonzero exit + Failure-derived stderr ----

  def test_org_add_invalid_ref_exits_nonzero_with_stderr_message
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      FileUtils.mkdir_p(paths.config_dir)
      File.write(paths.config_file, "base_dir: /tmp/evergreen\n")
      mtime_before = File.mtime(paths.config_file)
      bytes_before = File.read(paths.config_file)

      out, err = invoke_command(PristineCLI::Org::Add, name: "too/many/parts")
      assert_equal 1, PristineCLI.last_outcome.exit_code
      assert_includes err.string, "invalid org reference"
      assert_includes err.string, "\"too/many/parts\""
      assert_equal "", out.string

      # Config file unchanged.
      assert_equal bytes_before, File.read(paths.config_file)
      assert_equal mtime_before, File.mtime(paths.config_file)
    end
  end

  def test_org_add_invalid_ref_subprocess_exits_nonzero
    with_cli_env do |env, _home|
      _stdout, stderr, status = run_cli_subprocess(env: env, args: ["org", "add", "a/b/c"])
      refute status.success?, "subprocess should exit nonzero; got #{status.exitstatus}"
      assert_includes stderr, "invalid org reference"
    end
  end

  # ---- RC1/RC3: color in pretty mode, no color otherwise ----

  def test_org_add_has_color_in_pretty_mode
    with_cli_env do |_env, _home|
      tty_out = Class.new(StringIO) { def tty? = true }.new
      cmd = PristineCLI::Org::Add.new
      cmd.instance_variable_set(:@out, tty_out)
      cmd.instance_variable_set(:@err, StringIO.new)
      cmd.call(name: "github.com/socketry", plain: nil, json: nil, no_color: nil, quiet: nil)
      assert_match(/\e\[[0-9;]*m/, tty_out.string)
    end
  end

  def test_org_add_no_color_with_no_color_flag
    with_cli_env do |_env, _home|
      tty_out = Class.new(StringIO) { def tty? = true }.new
      cmd = PristineCLI::Org::Add.new
      cmd.instance_variable_set(:@out, tty_out)
      cmd.instance_variable_set(:@err, StringIO.new)
      cmd.call(name: "github.com/socketry", plain: nil, json: nil, no_color: true, quiet: nil)
      refute_match(/\e\[[0-9;]*m/, tty_out.string)
    end
  end

  def test_org_list_has_color_in_pretty_mode
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      RepoTender::Config::Store.write(paths.config_file,
        RepoTender::Config::Store.load(paths.config_file).success.new(
          orgs: [RepoTender::Config::OrgRef.new(host: "github.com", name: "socketry")]
        ))
      tty_out = Class.new(StringIO) { def tty? = true }.new
      cmd = PristineCLI::Org::List.new
      cmd.instance_variable_set(:@out, tty_out)
      cmd.instance_variable_set(:@err, StringIO.new)
      cmd.call(plain: nil, json: nil, no_color: nil, quiet: nil)
      assert_match(/\e\[[0-9;]*m/, tty_out.string)
    end
  end

  def test_org_list_no_color_in_non_tty
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      RepoTender::Config::Store.write(paths.config_file,
        RepoTender::Config::Store.load(paths.config_file).success.new(
          orgs: [RepoTender::Config::OrgRef.new(host: "github.com", name: "socketry")]
        ))
      out, _err = invoke_command(PristineCLI::Org::List)
      refute_match(/\e\[[0-9;]*m/, out.string)
    end
  end
end
