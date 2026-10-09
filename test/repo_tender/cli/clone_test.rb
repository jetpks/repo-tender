# frozen_string_literal: true

require_relative "test_helper"
require "repo_tender/cli/clone"

class CLICloneTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  PristineCLI = RepoTender::CLI

  # ---- GB4: CLI multi-repo, --into, partial failure, exit codes ----

  def test_clone_single_repo_succeeds
    with_clone_env do |env, base, into|
      seed_repo(base, "github.com", "owner", "myrepo", files: {"README.md" => "hi"})
      out, _err = invoke_command(PristineCLI::Clone, names: ["myrepo"], into: into)
      assert_equal 0, PristineCLI.last_outcome.exit_code
      assert File.directory?(File.join(into, "myrepo")), "dest must exist"
      assert_includes out.string, "cloned:"
      assert_includes out.string, "myrepo"
    end
  end

  def test_clone_two_repos_both_succeed
    with_clone_env do |env, base, into|
      seed_repo(base, "github.com", "owner", "alpha")
      seed_repo(base, "github.com", "owner", "beta")
      _, err = invoke_command(PristineCLI::Clone, names: ["alpha", "beta"], into: into)
      assert_equal 0, PristineCLI.last_outcome.exit_code, "err: #{err.string}"
      assert File.directory?(File.join(into, "alpha"))
      assert File.directory?(File.join(into, "beta"))
    end
  end

  def test_clone_partial_failure_bad_name_reports_err_and_exits_one
    with_clone_env do |env, base, into|
      seed_repo(base, "github.com", "owner", "goodrepo")
      _, err = invoke_command(PristineCLI::Clone, names: ["goodrepo", "nosuchrepo"], into: into)
      assert_equal 1, PristineCLI.last_outcome.exit_code
      assert File.directory?(File.join(into, "goodrepo")), "good repo must still be copied"
      assert_includes err.string, "not found"
    end
  end

  def test_clone_all_fail_exits_one
    with_clone_env do |env, base, into|
      _out, err = invoke_command(PristineCLI::Clone, names: ["nosuch"], into: into)
      assert_equal 1, PristineCLI.last_outcome.exit_code
      assert_includes err.string, "not found"
    end
  end

  def test_clone_default_into_is_current_dir
    with_clone_env do |env, base, into|
      seed_repo(base, "github.com", "owner", "myrepo")
      original_dir = Dir.pwd
      Dir.chdir(into) do
        _, _err = invoke_command(PristineCLI::Clone, names: ["myrepo"])
        assert_equal 0, PristineCLI.last_outcome.exit_code
        assert File.directory?(File.join(into, "myrepo")),
          "default into=. should copy into current working directory"
      end
    ensure
      Dir.chdir(original_dir)
    end
  end

  def test_clone_no_clobber_exits_one
    with_clone_env do |env, base, into|
      seed_repo(base, "github.com", "owner", "myrepo")
      FileUtils.mkdir_p(File.join(into, "myrepo"))
      _out, err = invoke_command(PristineCLI::Clone, names: ["myrepo"], into: into)
      assert_equal 1, PristineCLI.last_outcome.exit_code
      assert_includes err.string, "already exists"
    end
  end

  # ---- GB5: command is registered top-level ----

  def test_clone_registered_as_top_level_command
    with_clone_env do |env, _base, _into|
      stdout, stderr, status = run_cli_subprocess(env: env, args: ["clone", "--help"])
      assert status.success?, "clone --help should exit 0; stderr=#{stderr}"
      assert_includes stdout + stderr, "clone"
    end
  end

  def test_clone_appears_in_top_level_help
    with_clone_env do |env, _base, _into|
      stdout, _stderr, _status = run_cli_subprocess(env: env, args: ["--help"])
      assert_includes stdout, "clone"
    end
  end

  private

  def with_clone_env
    with_cli_env do |env, _home|
      Dir.mktmpdir("clone-base-") do |base|
        Dir.mktmpdir("clone-into-") do |into|
          paths = RepoTender::Paths.new(environment: env)
          paths.ensure!
          config = RepoTender::Config::Store.load(paths.config_file).success
          RepoTender::Config::Store.write(paths.config_file, config.new(base_dir: base))
          yield(env, base, into)
        end
      end
    end
  end

  def seed_repo(base, host, owner, name, files: {"SEED" => "seed"})
    path = File.join(base, host, owner, name)
    FileUtils.mkdir_p(path)
    files.each { |fname, content| File.write(File.join(path, fname), content) }
    path
  end
end
