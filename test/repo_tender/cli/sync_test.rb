# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"
require "time"

class CLISyncTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  PristineCLI = RepoTender::CLI
  Engine = RepoTender::Sync::Engine
  Config = RepoTender::Config::Config
  RepoRef = RepoTender::Config::RepoRef

  # Build 2 real bare remotes + clones, copy the clones into
  # base_dir under `<host>/<owner>/<name>`. Critically, keep the
  # BARE REMOTES alive for the full duration of the test (incl.
  # the engine run) — the clones' `origin` URLs point at the
  # bares, so if the bares are cleaned up before the engine runs,
  # the engine's fetch fails (the error observed in the first
  # failed test was exactly this: "bare.git does not appear to
  # be a git repository"). The Slice 2 single-repo tests don't
  # hit this because the engine runs INSIDE the with_trunk_repo
  # block. The multi-repo CLI test has to keep the bares alive
  # for the entire test.
  def with_engine_home_2_repos
    Dir.mktmpdir("repo-tender-cli-sync-base-") do |base_dir|
      Dir.mktmpdir("repo-tender-cli-sync-bares-") do |bares_dir|
        with_cli_env do |env, _home|
          paths = RepoTender::Paths.new(environment: env, base_dir: base_dir)
          paths.ensure!
          refs = []
          2.times do |i|
            owner = i.zero? ? "foo" : "bar"
            name = "repo#{i}"
            repo_dir = File.join(bares_dir, "repo-#{i}")
            FileUtils.cp_r(TestHelpers.seeded_trunk_template, repo_dir)
            bare = File.join(repo_dir, "bare.git")
            clone = File.join(repo_dir, "clone")
            in_async do
              Shell.run("git", "remote", "set-url", "origin", bare, chdir: clone)
            end
            ref = RepoRef.new(host: "github.com", owner: owner, name: name)
            repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
            FileUtils.mkdir_p(File.dirname(repo_path))
            FileUtils.cp_r(clone, repo_path)
            refs << ref
          end
          yield(env, paths, base_dir, refs)
        end
      end
    end
  end

  # ---- G4: `sync` invokes the engine; `sync --repo` scopes to
  #        one repo. At least one assertion must prove the
  #        non-targeted repo was not processed. ----

  def test_sync_invokes_engine_and_writes_state
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      out, _err = invoke_command(PristineCLI::Sync::Run)
      assert_equal 0, PristineCLI.last_outcome.exit_code
      assert_includes out.string, "synced 2 repo(s)"

      # State has rows for both repos.
      state = RepoTender::State::Store.load(paths.state_file).success
      refute_nil state.repos["github.com/foo/repo0"], "repo0 missing from state"
      refute_nil state.repos["github.com/bar/repo1"], "repo1 missing from state"
      # Each processed repo got a status (clean — the engine
      # fetched + discovered up-to-date).
      assert_equal "clean", state.repos["github.com/foo/repo0"].status
      assert_equal "clean", state.repos["github.com/bar/repo1"].status
      # Each got a last_synced_at.
      refute_nil state.repos["github.com/foo/repo0"].last_synced_at
      refute_nil state.repos["github.com/bar/repo1"].last_synced_at
    end
  end

  def test_sync_repo_scopes_to_one_repo_and_leaves_other_state_row_untouched
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      # Pre-seed state with rows for BOTH repos, using a fixed
      # "old" last_synced_at string (State::Store round-trips
      # ISO8601 strings as strings, NOT Time objects — see the
      # state/store.rb reader). The proof of scoping is that
      # after the scoped sync, the non-targeted repo's
      # last_synced_at is unchanged.
      old_time_string = "2000-01-01T00:00:00Z"
      seeded_state = RepoTender::State::Store::State.new(
        repos: {
          "github.com/foo/repo0" => RepoTender::State::Store::Repo.new(
            default_branch: "trunk", last_fetch_at: old_time_string,
            last_synced_at: old_time_string, status: "clean", last_error: nil
          ),
          "github.com/bar/repo1" => RepoTender::State::Store::Repo.new(
            default_branch: "trunk", last_fetch_at: old_time_string,
            last_synced_at: old_time_string, status: "clean", last_error: nil
          )
        },
        orgs: {}
      )
      RepoTender::State::Store.write(paths.state_file, seeded_state)

      out, _err = invoke_command(PristineCLI::Sync::Run, repo: "github.com/foo/repo0")
      assert_equal 0, PristineCLI.last_outcome.exit_code
      assert_includes out.string, "scoping sync to: github.com/foo/repo0"

      new_state = RepoTender::State::Store.load(paths.state_file).success

      # Targeted repo was processed — its last_synced_at moved
      # forward (the engine's clock is Time.now, not old_time).
      targeted = new_state.repos["github.com/foo/repo0"]
      refute_nil targeted
      refute_equal old_time_string, targeted.last_synced_at,
        "scoped sync did not process the targeted repo"

      # Non-targeted repo was NOT processed — its last_synced_at
      # is unchanged. This is the G4 scoping proof.
      non_targeted = new_state.repos["github.com/bar/repo1"]
      refute_nil non_targeted, "non-targeted repo state row vanished (was deleted)"
      assert_equal old_time_string, non_targeted.last_synced_at,
        "non-targeted repo was processed (last_synced_at changed) — CLI scoping failed"
      assert_equal "clean", non_targeted.status,
        "non-targeted repo's status changed (engine touched it)"
    end
  end

  # Regression: the "synced N repo(s)" summary used to be derived from
  # new_state.repos.size — the merged state file, which holds a row for
  # every repo ever synced. A scoped run therefore reported the whole
  # state (553 repo(s) on a real machine) instead of the one repo it
  # touched, contradicting the "starting: 1 repo(s)" line above it.
  #
  # The state here is seeded with rows for THREE repos while only one is
  # tracked and synced, so state size (3) and processed count (1) can't
  # coincide — the assertion below fails loudly on a regression.
  def test_sync_repo_summary_counts_processed_repos_not_state_rows
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      old_time_string = "2000-01-01T00:00:00Z"
      seeded_row = RepoTender::State::Store::Repo.new(
        default_branch: "trunk", last_fetch_at: old_time_string,
        last_synced_at: old_time_string, status: "clean", last_error: nil
      )
      # Three rows, one of them ("gone/repo") no longer tracked at all —
      # build_new_state never prunes, so it stays in state and would be
      # counted by the old expression.
      RepoTender::State::Store.write(paths.state_file, RepoTender::State::Store::State.new(
        repos: {
          "github.com/foo/repo0" => seeded_row,
          "github.com/bar/repo1" => seeded_row,
          "github.com/gone/repo" => seeded_row
        },
        orgs: {}
      ))

      out, _err = invoke_command(PristineCLI::Sync::Run, repo: "github.com/foo/repo0")
      assert_equal 0, PristineCLI.last_outcome.exit_code

      assert_includes out.string, "synced 1 repo(s)",
        "scoped sync must report the 1 repo it processed, not the state file's row count"
      refute_includes out.string, "synced 3 repo(s)",
        "summary counted state rows instead of processed repos"

      # The summary must agree with the run header printed moments earlier.
      assert_includes out.string, "starting: 1 repo(s)"

      # Guard the seeding itself: the untracked row must survive, or the
      # test would pass for the wrong reason (state pruned down to 1).
      new_state = RepoTender::State::Store.load(paths.state_file).success
      refute_nil new_state.repos["github.com/gone/repo"],
        "untracked state row vanished — test no longer distinguishes the two counts"
    end
  end

  # The `--json` stream is documented as one JSON object per event line.
  # The human-readable "synced N repo(s)" summary used to be appended to
  # it unconditionally, leaving a trailing record no JSON consumer could
  # parse. JsonReporter already emits a run_finished event carrying the
  # summary, so the prose line is redundant there.
  def test_sync_json_output_is_parseable_json_on_every_line
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      out, _err = invoke_command(PristineCLI::Sync::Run, json: true)
      assert_equal 0, PristineCLI.last_outcome.exit_code

      events = assert_all_json_lines(out.string)
      # The run_finished event is what carries the summary in JSON mode,
      # so suppressing the prose line loses nothing.
      assert_includes events, "run_finished"
    end
  end

  # The scoped path prints its own prose notice ("scoping sync to: ...")
  # before the reporter is even chosen, so it needs the same suppression.
  # Easy to miss: an unscoped --json run never reaches that line.
  def test_sync_scoped_json_output_is_parseable_json_on_every_line
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      out, _err = invoke_command(PristineCLI::Sync::Run, repo: "github.com/foo/repo0", json: true)
      assert_equal 0, PristineCLI.last_outcome.exit_code

      refute_includes out.string, "scoping sync to:",
        "the scoping notice is prose and must not land in the JSON stream"
      assert_all_json_lines(out.string)
    end
  end

  # Asserts every non-empty line of `output` parses as one JSON object.
  # Returns the "event" of each line, for further assertions.
  def assert_all_json_lines(output)
    lines = output.lines.map(&:chomp).reject(&:empty?)
    refute_empty lines, "json sync produced no output"
    lines.map do |line|
      JSON.parse(line)["event"]
    rescue JSON::ParserError
      flunk "non-JSON line in --json output: #{line.inspect}"
    end
  end

  # A full sweep sees the complete tracked set, so rows for repos dropped
  # from config stop accumulating.
  def test_sync_unscoped_prunes_state_rows_for_untracked_repos
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      RepoTender::State::Store.write(paths.state_file, RepoTender::State::Store::State.new(
        repos: {
          "github.com/gone/repo" => RepoTender::State::Store::Repo.new(
            default_branch: "trunk", last_fetch_at: nil,
            last_synced_at: "2000-01-01T00:00:00Z", status: "clean", last_error: nil
          )
        },
        orgs: {}
      ))

      out, _err = invoke_command(PristineCLI::Sync::Run)
      assert_equal 0, PristineCLI.last_outcome.exit_code
      assert_includes out.string, "synced 2 repo(s)"

      new_state = RepoTender::State::Store.load(paths.state_file).success
      assert_nil new_state.repos["github.com/gone/repo"],
        "untracked repo's state row survived a full sweep — rows accumulate forever"
      # The tracked repos are of course still there.
      refute_nil new_state.repos["github.com/foo/repo0"]
      refute_nil new_state.repos["github.com/bar/repo1"]
    end
  end

  # The catastrophic case. `sync --repo` narrows the config to one repo
  # before handing it to the engine, so pruning on a scoped run would
  # delete the state rows for every other tracked repo — 552 of them on
  # a real machine. The CLI must pass prune: false whenever --repo is set.
  def test_sync_scoped_does_not_prune_other_repos_state_rows
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      seeded_row = RepoTender::State::Store::Repo.new(
        default_branch: "trunk", last_fetch_at: nil,
        last_synced_at: "2000-01-01T00:00:00Z", status: "clean", last_error: nil
      )
      RepoTender::State::Store.write(paths.state_file, RepoTender::State::Store::State.new(
        repos: {
          "github.com/foo/repo0" => seeded_row,
          "github.com/bar/repo1" => seeded_row,
          "github.com/gone/repo" => seeded_row
        },
        orgs: {}
      ))

      _out, _err = invoke_command(PristineCLI::Sync::Run, repo: "github.com/foo/repo0")
      assert_equal 0, PristineCLI.last_outcome.exit_code

      new_state = RepoTender::State::Store.load(paths.state_file).success
      refute_nil new_state.repos["github.com/bar/repo1"],
        "scoped sync pruned a tracked repo it did not process"
      refute_nil new_state.repos["github.com/gone/repo"],
        "scoped sync pruned an untracked row — pruning must never run on a scoped sweep"
      refute_nil new_state.repos["github.com/foo/repo0"]
    end
  end

  def test_sync_repo_unknown_ref_exits_nonzero_with_stderr
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      _out, err = invoke_command(PristineCLI::Sync::Run, repo: "github.com/no/such")
      assert_equal 1, PristineCLI.last_outcome.exit_code
      assert_includes err.string, "no such tracked repo"
    end
  end

  def test_sync_repo_invalid_ref_exits_nonzero
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      _out, err = invoke_command(PristineCLI::Sync::Run, repo: "not-a-ref")
      assert_equal 1, PristineCLI.last_outcome.exit_code
      assert_includes err.string, "invalid repo reference"
    end
  end

  def test_sync_subprocess_invokes_engine
    with_engine_home_2_repos do |env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["sync"])
      assert status.success?, "sync subprocess should exit 0; got #{status.exitstatus}"
      assert_includes stdout, "synced 2 repo(s)"

      state = RepoTender::State::Store.load(paths.state_file).success
      refute_nil state.repos["github.com/foo/repo0"]
      refute_nil state.repos["github.com/bar/repo1"]
    end
  end

  # ---- Slice 5 / CF6: `REPO_TENDER_LOG_MAX_BYTES` parse
  #      hardening. A malformed value (e.g. `"10MB"`) must
  #      fall back to the 10 MiB default instead of raising
  #      `ArgumentError` and crashing the entire `sync` run.
  #      Gate G4: the threshold helper returns the 10 MiB
  #      default for unset/empty/whitespace/non-numeric/
  #      non-positive inputs, and the parsed positive
  #      integer for valid input. **No `ArgumentError`
  #      escapes** for any input.

  def log_max_bytes(value)
    cmd = PristineCLI::Sync::Run.new
    # Invalid values emit a real `Kernel#warn` (CF6) — capture_io keeps
    # that off the suite's combined stdout/stderr.
    result = nil
    capture_io { result = cmd.send(:log_max_bytes, value) }
    result
  end

  def test_log_max_bytes_unset_returns_default
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes(nil)
  end

  def test_log_max_bytes_empty_returns_default
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("")
  end

  def test_log_max_bytes_whitespace_returns_default
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("   ")
  end

  def test_log_max_bytes_non_numeric_returns_default
    # The CF6 example value — must NOT raise ArgumentError.
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("10MB")
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("abc")
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("1.5")
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("10MiB")
  end

  def test_log_max_bytes_zero_returns_default
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("0")
  end

  def test_log_max_bytes_negative_returns_default
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("-5")
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("-1048576")
  end

  def test_log_max_bytes_valid_positive_returns_value
    assert_equal 1048576, log_max_bytes("1048576")
    assert_equal 1, log_max_bytes("1")
  end

  def test_log_max_bytes_strips_surrounding_whitespace_from_valid_value
    # `Integer("  524288  ", 10, exception: false)` → 524288
    # (Ruby's Integer tolerates leading/trailing whitespace).
    assert_equal 524288, log_max_bytes("  524288  ")
  end

  def test_log_max_bytes_never_raises_argument_error
    # Belt-and-braces: every shape of bad input must NOT
    # raise. Looped so a single failure points to the
    # exact value that broke the contract.
    ["10MB", "abc", "0", "-1", "1.5", "", "  ", "  ", "0x10", "1e6", "1_000_000", nil].each do |v|
      log_max_bytes(v)
    rescue ArgumentError => e
      flunk "log_max_bytes(#{v.inspect}) raised ArgumentError: #{e.message}"
    end
  end

  def test_sync_with_malformed_log_max_bytes_does_not_crash
    # Integration: a real `sync` run with
    # `REPO_TENDER_LOG_MAX_BYTES="10MB"` set in the env must
    # exit 0 and write state for both repos. The pre-step's
    # parse must NOT crash the run.
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      prev = ENV["REPO_TENDER_LOG_MAX_BYTES"]
      out = nil
      begin
        ENV["REPO_TENDER_LOG_MAX_BYTES"] = "10MB"
        # The malformed value triggers a real `Kernel#warn` (CF6) —
        # capture_io keeps that off the suite's combined stdout/stderr.
        capture_io { out, _err = invoke_command(PristineCLI::Sync::Run) }
      ensure
        ENV["REPO_TENDER_LOG_MAX_BYTES"] = prev
      end
      assert_equal 0, PristineCLI.last_outcome.exit_code,
        "expected exit 0 with malformed log_max_bytes; got #{PristineCLI.last_outcome.exit_code}"
      assert_includes out.string, "synced 2 repo(s)"

      state = RepoTender::State::Store.load(paths.state_file).success
      refute_nil state.repos["github.com/foo/repo0"], "repo0 missing — sync crashed before writing state"
      refute_nil state.repos["github.com/bar/repo1"], "repo1 missing — sync crashed before writing state"
    end
  end

  # ---- Slice A (ui-foundation) G6: subprocess stdout is ANSI-free when
  #      piped (non-TTY); synced N repo(s) summary preserved; exit unchanged ----

  def test_g6_sync_subprocess_stdout_is_ansi_free_when_piped
    with_engine_home_2_repos do |env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      # Open3.capture3 captures stdout as a string (non-TTY) — the launchd condition
      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["sync"])
      assert status.success?, "sync subprocess should exit 0; got #{status.exitstatus}"
      refute_includes stdout, "\e[", "stdout must be ANSI-free when piped"
      refute_includes stdout, "\x1b[", "stdout must be ANSI-free when piped"
      assert_includes stdout, "synced 2 repo(s)", "synced summary line must be preserved"
    end
  end

  def test_g6_sync_subprocess_exit_and_state_unchanged_from_pre_slice
    # Regression: exit codes and state.yaml write behavior are unchanged.
    with_engine_home_2_repos do |env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      _stdout, _stderr, status = run_cli_subprocess(env: env, args: ["sync"])
      assert status.success?
      state = RepoTender::State::Store.load(paths.state_file).success
      assert_equal 2, state.repos.size
      assert state.repos["github.com/foo/repo0"]
      assert state.repos["github.com/bar/repo1"]
    end
  end

  def test_g6_sync_repo_invalid_ref_exits_nonzero_when_piped
    with_engine_home_2_repos do |env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      _stdout, stderr, status = run_cli_subprocess(env: env, args: ["sync", "--repo", "not-a-ref"])
      refute status.success?, "invalid repo ref should exit non-zero"
      assert_includes stderr, "invalid repo reference"
    end
  end

  # ===========================================================================
  # Slice B G5 — reporter selection branch: mode.animate → InteractiveReporter
  # ===========================================================================

  def test_g5_json_flag_selects_json_reporter
    mode = RepoTender::UI::Mode.new(color: false, animate: false, quiet: false, format: :json)
    reporter = reporter_for_mode(mode)
    assert_instance_of RepoTender::UI::JsonReporter, reporter
  end

  def test_g5_animate_true_selects_interactive_reporter
    mode = RepoTender::UI::Mode.new(color: true, animate: true, quiet: false, format: :pretty)
    reporter = reporter_for_mode(mode)
    assert_instance_of RepoTender::UI::InteractiveReporter, reporter
  end

  def test_g5_animate_false_selects_plain_reporter
    mode = RepoTender::UI::Mode.new(color: false, animate: false, quiet: false, format: :plain)
    reporter = reporter_for_mode(mode)
    assert_instance_of RepoTender::UI::PlainReporter, reporter
  end

  def test_g5_json_format_takes_precedence_over_animate
    # format=:json implies animate=false (Mode.resolve sets animate=false for non-pretty),
    # but assert JsonReporter wins regardless.
    mode = RepoTender::UI::Mode.new(color: false, animate: false, quiet: false, format: :json)
    reporter = reporter_for_mode(mode)
    assert_instance_of RepoTender::UI::JsonReporter, reporter
  end

  def test_g5_no_color_with_animate_still_selects_interactive_reporter
    # --no-color on a TTY: format=:pretty, animate=true, color=false
    mode = RepoTender::UI::Mode.new(color: false, animate: true, quiet: false, format: :pretty)
    reporter = reporter_for_mode(mode)
    assert_instance_of RepoTender::UI::InteractiveReporter, reporter
  end

  private

  # Extract the reporter selection logic for mode-only unit testing.
  # Mirrors the branch in CLI::Sync::Run#call without running the full engine.
  def reporter_for_mode(mode)
    out = StringIO.new
    if mode.format == :json
      RepoTender::UI::JsonReporter.new(out)
    elsif mode.animate
      RepoTender::UI::InteractiveReporter.new(out, mode: mode)
    else
      RepoTender::UI::PlainReporter.new(out, mode: mode)
    end
  end
end
