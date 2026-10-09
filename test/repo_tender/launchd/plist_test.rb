# frozen_string_literal: true

require "test_helper"
require "tempfile"

class LaunchdPlistTest < Minitest::Test
  include TestHelpers

  Plist = RepoTender::Launchd::Plist

  LABEL = RepoTender::Launchd::Agent::DEFAULT_LABEL
  MISE_BIN = "/opt/homebrew/opt/mise/bin/mise"
  RUBY_BIN = "/Users/eric/.local/share/mise/installs/ruby/latest/bin/ruby"
  REPO_ROOT = "/Users/eric/src/github.com/jetpks/repo-tender"
  MISE_TOML = "#{REPO_ROOT}/mise.toml".freeze
  BIN_PATH = "#{REPO_ROOT}/bin/repo-tender".freeze
  LOG_DIR = "/Users/eric/.local/state/repo-tender/logs"

  def fixture_xml
    Plist.call(
      label: LABEL,
      refresh_interval: 3600,
      log_dir: LOG_DIR,
      repo_root: REPO_ROOT,
      mise_toml: MISE_TOML,
      mise_bin: MISE_BIN,
      ruby_bin: RUBY_BIN,
      bin_path: BIN_PATH
    )
  end

  # ---- G1: plist is well-formed + lint-clean ----

  def test_emitted_plist_is_plutil_lint_clean
    Tempfile.create(["plist", ".plist"]) do |f|
      f.write(fixture_xml)
      f.flush
      # The lint is the canonical macOS plist validator — runs
      # offline, deterministic.
      out = `plutil -lint #{f.path} 2>&1`
      assert_equal 0, $?.exitstatus, "plutil -lint failed: #{out}"
      assert_match(/OK/, out)
    end
  end

  def test_emitted_plist_contains_label
    assert_match(/<key>Label<\/key>\s*<string>#{Regexp.escape(LABEL)}<\/string>/o, fixture_xml)
  end

  def test_emitted_plist_contains_program_arguments_with_absolute_mise
    xml = fixture_xml
    assert_match(/<key>ProgramArguments<\/key>/, xml)
    m = xml.match(/<key>ProgramArguments<\/key>\s*<array>(.*?)<\/array>/m)
    refute_nil m, "ProgramArguments array missing"
    args = m[1].scan(/<string>([^<]*)<\/string>/).flatten
    assert_equal [MISE_BIN, "exec", "--", RUBY_BIN, BIN_PATH, "sync"], args
  end

  def test_emitted_plist_contains_start_interval_run_at_load_process_type
    xml = fixture_xml
    assert_match(/<key>StartInterval<\/key>\s*<integer>3600<\/integer>/, xml)
    assert_match(/<key>RunAtLoad<\/key>\s*<true\/>/, xml)
    assert_match(/<key>ProcessType<\/key>\s*<string>Background<\/string>/, xml)
  end

  def test_emitted_plist_contains_absolute_log_paths
    xml = fixture_xml
    assert_match(/<key>StandardOutPath<\/key>\s*<string>#{Regexp.escape(File.join(LOG_DIR, "#{LABEL}.out.log"))}<\/string>/, xml)
    assert_match(/<key>StandardErrorPath<\/key>\s*<string>#{Regexp.escape(File.join(LOG_DIR, "#{LABEL}.err.log"))}<\/string>/, xml)
  end

  def test_emitted_plist_has_no_keep_alive
    refute_match(/<key>KeepAlive<\/key>/, fixture_xml)
  end

  def test_emitted_plist_has_no_literal_tilde_or_home_in_values
    # Match every <string> value in the plist and assert none
    # contain a leading `~` or literal `$HOME`.
    xml = fixture_xml
    xml.scan(/<string>([^<]*)<\/string>/).flatten.each do |v|
      refute_match(/\A~/, v, "value '#{v}' starts with a literal ~")
      refute_match(/\$HOME/, v, "value '#{v}' contains literal $HOME")
    end
  end

  def test_emitted_plist_pins_mise_config_file_and_working_directory
    xml = fixture_xml
    assert_match(/<key>WorkingDirectory<\/key>\s*<string>#{Regexp.escape(REPO_ROOT)}<\/string>/o, xml)
    assert_match(/<key>EnvironmentVariables<\/key>/, xml)
    assert_match(/<key>MISE_CONFIG_FILE<\/key>\s*<string>#{Regexp.escape(MISE_TOML)}<\/string>/o, xml)
  end

  # ---- Defensive: input validation ----

  def test_rejects_empty_label
    assert_raises(ArgumentError) do
      Plist.call(
        label: "",
        refresh_interval: 3600,
        log_dir: LOG_DIR,
        repo_root: REPO_ROOT,
        mise_toml: MISE_TOML,
        mise_bin: MISE_BIN,
        ruby_bin: RUBY_BIN,
        bin_path: BIN_PATH
      )
    end
  end

  def test_rejects_non_positive_refresh_interval
    [0, -1, "3600"].each do |bad|
      assert_raises(ArgumentError) do
        Plist.call(
          label: LABEL,
          refresh_interval: bad,
          log_dir: LOG_DIR,
          repo_root: REPO_ROOT,
          mise_toml: MISE_TOML,
          mise_bin: MISE_BIN,
          ruby_bin: RUBY_BIN,
          bin_path: BIN_PATH
        )
      end
    end
  end

  def test_rejects_relative_paths
    assert_raises(ArgumentError) do
      Plist.call(
        label: LABEL,
        refresh_interval: 3600,
        log_dir: "relative/log",
        repo_root: REPO_ROOT,
        mise_toml: MISE_TOML,
        mise_bin: MISE_BIN,
        ruby_bin: RUBY_BIN,
        bin_path: BIN_PATH
      )
    end
  end
end
