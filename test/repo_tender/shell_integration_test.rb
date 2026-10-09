# frozen_string_literal: true

require_relative "cli/test_helper"
require "repo_tender/shell_integration"
require "repo_tender/cli"

class SrcShellIntegrationTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  ShellIntegration = RepoTender::ShellIntegration
  CLI = RepoTender::CLI

  def fish_script
    @fish_script ||= ShellIntegration.for("fish")
  end

  def fish_completions
    @fish_completions ||= ShellIntegration.completions_for("fish")
  end

  # ---- independence: no Space::Architect, no Space::Core ----

  def test_module_has_no_space_architect_reference
    src = File.read(File.expand_path("../../lib/repo_tender/shell_integration.rb", __dir__))
    refute_match(/space_?architect/i, src,
      "shell_integration.rb must not reference Space::Architect")
  end

  def test_module_has_no_space_core_reference
    src = File.read(File.expand_path("../../lib/repo_tender/shell_integration.rb", __dir__))
    refute_match(/Space::Core|space_core/i, src,
      "shell_integration.rb must not reference Space::Core / space_core")
  end

  def test_cli_shell_has_no_space_architect_reference
    src = File.read(File.expand_path("../../lib/repo_tender/cli/shell.rb", __dir__))
    refute_match(/space_?architect/i, src,
      "cli/shell.rb must not reference Space::Architect")
  end

  def test_cli_shell_has_no_space_core_reference
    src = File.read(File.expand_path("../../lib/repo_tender/cli/shell.rb", __dir__))
    refute_match(/Space::Core|space_core/i, src,
      "cli/shell.rb must not reference Space::Core / space_core")
  end

  def test_fish_script_has_no_space_architect_reference
    refute_match(/space_?architect/i, fish_script,
      "generated fish script must not reference Space::Architect")
  end

  def test_fish_script_has_no_space_core_reference
    refute_match(/Space::Core|space_core/i, fish_script,
      "generated fish script must not reference Space::Core / space_core")
  end

  def test_fish_completions_have_no_space_architect_reference
    refute_match(/space_?architect/i, fish_completions,
      "generated fish completions must not reference Space::Architect")
  end

  def test_fish_completions_have_no_space_core_reference
    refute_match(/Space::Core|space_core/i, fish_completions,
      "generated fish completions must not reference Space::Core / space_core")
  end

  # ---- script defines function repo-tender ----

  def test_fish_script_defines_function_src
    assert_includes fish_script, "function repo-tender",
      "fish script must define function repo-tender"
  end

  # ---- cd logic: captures and prints output ----

  def test_fish_script_captures_command_output
    assert_match(/set.*__repo_tender_output.*command repo-tender/, fish_script,
      "fish script must capture src output into a variable")
  end

  def test_fish_script_prints_captured_output
    assert_match(/printf.*__repo_tender_output/, fish_script,
      "fish script must print captured output")
  end

  # ---- cd logic: IFF exit status 0, take last line ----

  def test_fish_script_checks_exit_status_0
    assert_match(/if test.*__repo_tender_status.*-eq 0/, fish_script,
      "fish script must gate cd on exit status 0")
  end

  def test_fish_script_takes_last_output_line
    assert_match(/__repo_tender_output\[-1\]/, fish_script,
      "fish script must take the last output line")
  end

  # ---- cd logic: tilde expansion ----

  def test_fish_script_tilde_expands
    assert_match(/string replace.*\^~/, fish_script,
      "fish script must tilde-expand the target path")
  end

  # ---- cd logic: guards on test -d ----

  def test_fish_script_guards_on_directory
    assert_match(/if test -d/, fish_script,
      "fish script must guard on the path being a directory before cd")
  end

  # ---- cd logic: cds into the target ----

  def test_fish_script_cds_into_target
    assert_includes fish_script, "cd \"$__repo_tender_target\"",
      "fish script must cd into the resolved path"
  end

  # ---- known subcommands do NOT cd ----

  def test_fish_script_passes_through_known_subcommands_without_cd
    assert_match(/case repo org sync status config daemon clone shell/, fish_script,
      "fish script must list known subcommands in a pass-through case")
  end

  def test_fish_script_known_subcommands_branch_has_no_cd
    lines = fish_script.lines
    passthrough_start = lines.index { |l| l.include?("case repo org") }
    wildcard_start = lines.index { |l| l.strip == "case '*'" }
    assert passthrough_start, "must have a pass-through case"
    assert wildcard_start, "must have a wildcard case"
    passthrough_lines = lines[passthrough_start...wildcard_start].join
    refute_includes passthrough_lines, "cd \"$__repo_tender_target\"",
      "pass-through branch must not contain a cd call"
  end

  # ---- version check in function ----

  def test_fish_script_contains_version_check
    assert_includes fish_script, "__repo_tender_compat_checked",
      "fish script must contain the version-compat guard"
  end

  def test_fish_script_version_substituted
    assert_includes fish_script, RepoTender::VERSION,
      "fish script must have __SRC_VERSION__ substituted with the gem version"
    refute_includes fish_script, "__SRC_VERSION__",
      "fish script must not contain the raw placeholder"
  end

  # ---- completions_for ----

  def test_completions_for_fish_returns_complete_c_src
    assert_includes fish_completions, "complete -c repo-tender",
      "completions must contain complete -c repo-tender"
  end

  def test_completions_for_fish_defines_helper_predicates
    assert_includes fish_completions, "__repo_tender_complete_needs_command",
      "completions must define __repo_tender_complete_needs_command"
    assert_includes fish_completions, "__repo_tender_complete_using_command",
      "completions must define __repo_tender_complete_using_command"
    assert_includes fish_completions, "__repo_tender_complete_first_argument_is",
      "completions must define __repo_tender_complete_first_argument_is"
  end

  def test_completions_for_fish_includes_checkouts_callback
    assert_includes fish_completions, "command repo-tender shell complete",
      "completions must call back into command repo-tender shell complete"
    assert_includes fish_completions, "checkouts",
      "completions must reference checkouts kind"
  end

  def test_completions_for_fish_includes_top_level_subcommands
    %w[clone config daemon org repo shell status sync].each do |cmd|
      assert_includes fish_completions, cmd,
        "completions must include top-level subcommand #{cmd}"
    end
  end

  def test_completions_for_unsupported_shell_raises
    assert_raises(RuntimeError) { ShellIntegration.completions_for("zsh") }
  end

  # ---- path_for / completions_path_for ----

  def test_path_for_fish_returns_under_config_home
    with_temp_home do |env, home|
      path = ShellIntegration.path_for("fish", env: env)
      assert path.to_s.start_with?(home),
        "path_for must be under the injected temp home"
      assert path.to_s.end_with?("fish/functions/repo-tender.fish"),
        "path_for must be the fish/functions/repo-tender.fish file"
    end
  end

  def test_completions_path_for_fish_returns_under_config_home
    with_temp_home do |env, home|
      path = ShellIntegration.completions_path_for("fish", env: env)
      assert path.to_s.start_with?(home),
        "completions_path_for must be under the injected temp home"
      assert path.to_s.end_with?("fish/completions/repo-tender.fish"),
        "completions_path_for must be the fish/completions/repo-tender.fish file"
    end
  end

  # ---- install / uninstall isolation and idempotency ----

  def test_install_writes_both_files_under_temp_home
    with_temp_home do |env, home|
      ShellIntegration.install("fish", env: env, force: false)
      fn_path = ShellIntegration.path_for("fish", env: env)
      co_path = ShellIntegration.completions_path_for("fish", env: env)

      assert fn_path.to_s.start_with?(home), "function file must be under temp home"
      assert File.exist?(fn_path), "function file must exist after install"
      assert co_path.to_s.start_with?(home), "completions file must be under temp home"
      assert File.exist?(co_path), "completions file must exist after install"
    end
  end

  def test_install_completions_file_is_src_completions
    with_temp_home do |env, _home|
      ShellIntegration.install("fish", env: env, force: false)
      co_path = ShellIntegration.completions_path_for("fish", env: env)
      assert_includes File.read(co_path), "complete -c repo-tender",
        "installed completions file must be the repo-tender completions"
    end
  end

  def test_install_is_idempotent
    with_temp_home do |env, _home|
      ShellIntegration.install("fish", env: env, force: false)
      result = ShellIntegration.install("fish", env: env, force: false)
      assert_equal :unchanged, result.fetch(:action),
        "second install must be :unchanged"
      assert_equal :unchanged, result.fetch(:completions_action),
        "second completions install must be :unchanged"
    end
  end

  def test_install_returns_installed_on_first_run
    with_temp_home do |env, _home|
      result = ShellIntegration.install("fish", env: env, force: false)
      assert_equal :installed, result.fetch(:action)
      assert_equal :installed, result.fetch(:completions_action)
    end
  end

  def test_uninstall_removes_both_files
    with_temp_home do |env, _home|
      ShellIntegration.install("fish", env: env, force: false)
      fn_path = ShellIntegration.path_for("fish", env: env)
      co_path = ShellIntegration.completions_path_for("fish", env: env)

      result = ShellIntegration.uninstall("fish", env: env, force: false)
      assert_equal :removed, result.fetch(:action)
      assert_equal :removed, result.fetch(:completions_action)
      refute File.exist?(fn_path), "function file must be removed"
      refute File.exist?(co_path), "completions file must be removed"
    end
  end

  def test_uninstall_on_missing_files_returns_missing
    with_temp_home do |env, _home|
      result = ShellIntegration.uninstall("fish", env: env, force: false)
      assert_equal :missing, result.fetch(:action)
      assert_equal :missing, result.fetch(:completions_action)
    end
  end

  def test_install_refuses_to_clobber_unmanaged_file
    with_temp_home do |env, _home|
      fn_path = ShellIntegration.path_for("fish", env: env)
      FileUtils.mkdir_p(File.dirname(fn_path))
      File.write(fn_path, "# some other fish config\n")
      assert_raises(RuntimeError) do
        ShellIntegration.install("fish", env: env, force: false)
      end
    end
  end

  def test_install_force_overwrites_unmanaged_file
    with_temp_home do |env, _home|
      fn_path = ShellIntegration.path_for("fish", env: env)
      FileUtils.mkdir_p(File.dirname(fn_path))
      File.write(fn_path, "# some other fish config\n")
      result = ShellIntegration.install("fish", env: env, force: true)
      assert_equal :updated, result.fetch(:action)
      assert_includes File.read(fn_path), "function repo-tender"
    end
  end

  def test_install_does_not_touch_real_fish_config
    with_temp_home do |env, home|
      ShellIntegration.install("fish", env: env, force: false)
      real_fish = File.expand_path("~/.config/fish")
      # Only assert isolation if the real fish dir exists
      if File.exist?(real_fish)
        fn_path = ShellIntegration.path_for("fish", env: env)
        refute fn_path.to_s.start_with?(real_fish),
          "installed path must not be inside the real ~/.config/fish"
      end
      # Primary assertion: everything is under the temp home
      fn_path = ShellIntegration.path_for("fish", env: env)
      assert fn_path.to_s.start_with?(home),
        "must be isolated under temp home #{home}"
    end
  end

  # ---- repo-tender shell init fish command ----

  def test_src_shell_init_fish_prints_fish_script
    with_cli_env do
      out, _err = invoke_command(CLI::Shell::Init, shell_name: "fish")
      assert_equal 0, CLI.last_outcome.exit_code
      assert_includes out.string, "function repo-tender"
    end
  end

  def test_src_shell_init_unknown_shell_exits_1
    with_cli_env do
      _out, err = invoke_command(CLI::Shell::Init, shell_name: "zsh")
      assert_equal 1, CLI.last_outcome.exit_code
      assert_includes err.string, "zsh"
    end
  end

  # ---- shell is registered as a top-level group ----

  def test_shell_is_registered_in_registry
    assert CLI::Registry.get([]).children.key?("shell"),
      "shell must be a registered top-level group"
  end
end
