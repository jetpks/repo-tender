# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# End-to-end (subprocess) coverage for the two executables:
#   exe/repo-tender — the primary binary
#   exe/src         — the deprecation shim: warns on stderr on EVERY
#                     invocation, then forwards argv/stdout/exit codes
#                     unchanged to RepoTender::CLI.
class CLIRepoTenderTest < Minitest::Test
  include TestHelpers

  EXE_DIR = File.expand_path("../exe", __dir__)
  DEPRECATION_WARNING = "src is deprecated; use repo-tender instead"

  def run_binary(name, *args)
    with_temp_home do |env, _home|
      out, err, status = Open3.capture3(env, File.join(EXE_DIR, name), *args)
      [out, err, status.exitstatus]
    end
  end

  # ---- primary binary basics ----

  def test_primary_version_prints_version_and_exits_0
    out, err, code = run_binary("repo-tender", "--version")
    assert_equal "1.0.0", out.chomp
    assert_equal 0, code
    assert_empty err
  end

  def test_primary_help_prints_usage_and_exits_0
    out, err, code = run_binary("repo-tender", "--help")
    assert_equal 0, code
    assert_match(/Commands:/, out)
    assert_empty err
  end

  def test_primary_status_reports_empty_state_and_exits_0
    out, err, code = run_binary("repo-tender", "status")
    assert_equal 0, code
    assert_match(/no repos in state/, out)
    assert_empty err
  end

  # ---- shim: warns on EVERY invocation ----

  def test_shim_warns_on_version
    out, err, code = run_binary("src", "--version")
    assert_equal 0, code
    assert_equal "1.0.0", out.chomp
    assert_includes err, DEPRECATION_WARNING
  end

  def test_shim_warns_on_help
    out, err, code = run_binary("src", "--help")
    assert_equal 0, code
    assert_match(/Commands:/, out)
    assert_includes err, DEPRECATION_WARNING
  end

  def test_shim_warns_on_plain_status
    out, err, code = run_binary("src", "status")
    assert_equal 0, code
    assert_match(/no repos in state/, out)
    assert_includes err, DEPRECATION_WARNING
  end

  def test_shim_warns_on_failing_invocation
    _, err, code = run_binary("src", "zqxnomatch")
    assert_equal 1, code
    assert_includes err, DEPRECATION_WARNING
  end

  # ---- shim: argv/stdout/exit-code parity with the primary binary ----

  def test_shim_parity_version
    primary = run_binary("repo-tender", "--version")
    shim = run_binary("src", "--version")
    assert_equal primary[0], shim[0], "stdout must be identical"
    assert_equal primary[2], shim[2], "exit code must be identical"
  end

  def test_shim_parity_version_word
    primary = run_binary("repo-tender", "version")
    shim = run_binary("src", "version")
    assert_equal primary[0], shim[0]
    assert_equal primary[2], shim[2]
  end

  def test_shim_parity_help
    primary = run_binary("repo-tender", "--help")
    shim = run_binary("src", "--help")
    assert_equal primary[0], shim[0], "stdout must be identical"
    assert_equal primary[2], shim[2], "exit code must be identical"
  end

  def test_shim_parity_status
    primary = run_binary("repo-tender", "status")
    shim = run_binary("src", "status")
    assert_equal primary[0], shim[0]
    assert_equal primary[2], shim[2]
  end

  def test_shim_parity_unknown_token
    primary = run_binary("repo-tender", "zqxnomatch")
    shim = run_binary("src", "zqxnomatch")
    assert_equal primary[0], shim[0]
    assert_equal primary[2], shim[2]
  end

  def test_shim_warning_goes_to_stderr_not_stdout
    out, err, = run_binary("src", "--version")
    refute_includes out, DEPRECATION_WARNING
    assert_includes err, DEPRECATION_WARNING
  end
end
