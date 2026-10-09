# frozen_string_literal: true

require "test_helper"

class ShellTest < Minitest::Test
  include TestHelpers

  Shell = RepoTender::Shell

  # G4: Shell is non-blocking. A zero-exit run returns Success(stdout);
  # a non-zero exit returns Failure carrying argv + stderr + status;
  # two concurrent runs inside one Sync{} overlap (wall-clock < 0.6s).

  def test_success_returns_stdout
    in_async do
      result = Shell.run("echo", "hi")
      assert result.success?
      assert_equal "hi\n", result.success
    end
  end

  def test_success_with_chdir
    in_async do
      result = Shell.run("pwd", chdir: "/tmp")
      assert result.success?
      assert_includes result.success, "tmp"
    end
  end

  def test_nonzero_returns_failure_with_argv_stderr_status
    in_async do
      result = Shell.run("sh", "-c", "echo oops 1>&2; exit 3")
      assert result.failure?
      f = result.failure
      assert_equal ["sh", "-c", "echo oops 1>&2; exit 3"], f[:argv]
      assert_equal 3, f[:status]
      assert_equal "oops\n", f[:stderr]
    end
  end

  def test_env_is_passed_through
    in_async do
      result = Shell.run("sh", "-c", "echo $MYVAR", env: {MYVAR: "hello"})
      assert result.success?
      assert_equal "hello\n", result.success
    end
  end

  def test_concurrent_runs_overlap_in_one_sync
    in_async do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      barrier = Async::Barrier.new
      barrier.async { Shell.run("sh", "-c", "sleep 0.3") }
      barrier.async { Shell.run("sh", "-c", "sleep 0.3") }
      barrier.wait
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      # Sequential would be ≥0.6s; concurrent via the Fiber scheduler
      # finishes at ~0.3s. Assert < 0.6s with a comfortable margin.
      assert_operator elapsed, :<, 0.6, "expected concurrent runs to overlap, took #{elapsed.round(3)}s"
    end
  end

  def test_outside_async_raises
    error = assert_raises(RuntimeError) do
      Shell.run("echo", "hi")
    end
    assert_match(/Async::Task/, error.message)
  end

  # ---------------------------------------------------------------------------
  # Slice 6 G3 — Open3 reader-thread noise suppression (mechanism
  # justification). Open3.capture3's internal stdout/stderr reader
  # threads can raise `IOError: stream closed in another thread` if
  # the main thread is interrupted while they are mid-read (the
  # ^C-during-a-clone scenario from the field defect). With
  # `Thread.report_on_exception = true` (the default since Ruby
  # 2.5), Ruby prints a multi-line backtrace for that orphaned
  # thread. The fix brackets the `Open3.capture3` call in `Shell.run`
  # with a save/restore of `Thread.report_on_exception = false`.
  #
  # This test pins the mechanism: it asserts that, during the
  # `Open3.capture3` call, `Thread.report_on_exception` is observed
  # to be `false`, and that the original value is restored after
  # the call returns (success or failure). The shim around
  # `Open3.capture3` records the value from inside the call site.
  # ---------------------------------------------------------------------------
  def test_shell_run_disables_thread_report_on_exception_during_open3_capture3
    require "open3"
    # Record the pre-call value to assert restoration at the end.
    pre = Thread.report_on_exception

    observed = {value: nil, restored: nil}
    original = Open3.method(:capture3)
    Open3.singleton_class.send(:remove_method, :capture3)
    Open3.define_singleton_method(:capture3) do |*args, **opts, &blk|
      # Record the value at the moment Shell.run's call is in
      # flight — this is the exact line the production code
      # brackets the suppression around.
      observed[:value] = Thread.report_on_exception
      original.call(*args, **opts, &blk)
    end

    begin
      in_async do
        Shell.run("true")
      end
      # After the call returns, the original value must be restored.
      observed[:restored] = Thread.report_on_exception
    ensure
      Open3.singleton_class.send(:remove_method, :capture3)
      Open3.define_singleton_method(:capture3, original)
    end

    assert_equal false, observed[:value],
      "Thread.report_on_exception must be false during Open3.capture3 call " \
        "(Slice 6 G3 suppression); saw #{observed[:value].inspect}"
    assert_equal pre, observed[:restored],
      "Thread.report_on_exception must be restored to the pre-call value " \
        "after Shell.run returns; pre=#{pre.inspect} restored=#{observed[:restored].inspect}"
  end

  # G8.2 + G8.3 — Refcount: no leak after concurrent runs; suppression intact
  # during overlap. Sets Thread.report_on_exception=true beforehand, launches
  # ≥2 genuinely overlapping Shell.run calls (each sleep 0.2s so they overlap),
  # shims Open3.capture3 to record the flag at each in-flight call, waits for
  # all, then asserts restoration (G8.2) and that all in-flight observations
  # were false (G8.3).
  def test_refcount_no_leak_and_suppression_during_concurrent_runs
    original = Thread.report_on_exception
    Thread.report_on_exception = true

    observed = []
    original_capture3 = Open3.method(:capture3)
    Open3.singleton_class.send(:remove_method, :capture3)
    Open3.define_singleton_method(:capture3) do |*args, **opts, &blk|
      observed << Thread.report_on_exception
      original_capture3.call(*args, **opts, &blk)
    end

    begin
      in_async do
        barrier = Async::Barrier.new
        barrier.async { Shell.run("sh", "-c", "sleep 0.2") }
        barrier.async { Shell.run("sh", "-c", "sleep 0.2") }
        barrier.async { Shell.run("sh", "-c", "sleep 0.2") }
        barrier.wait
      end

      # G8.2: restored — no leaked false after all concurrent runs complete
      assert_equal true, Thread.report_on_exception,
        "Thread.report_on_exception must be restored to true after concurrent Shell.run calls; was #{Thread.report_on_exception.inspect}"

      # G8.3: suppression was active during every in-flight capture3 call
      assert_equal 3, observed.size, "expected 3 capture3 observations"
      assert observed.all? { |v| v == false },
        "Thread.report_on_exception must be false during all in-flight Shell.run calls; saw #{observed.inspect}"
    ensure
      Open3.singleton_class.send(:remove_method, :capture3)
      Open3.define_singleton_method(:capture3, original_capture3)
      Thread.report_on_exception = original
    end
  end

  def test_shell_run_restores_thread_report_on_exception_even_when_open3_raises
    require "open3"
    pre = Thread.report_on_exception
    observed = {value: nil, restored: nil}
    original = Open3.method(:capture3)
    Open3.singleton_class.send(:remove_method, :capture3)
    Open3.define_singleton_method(:capture3) do |*args, **opts, &blk|
      observed[:value] = Thread.report_on_exception
      raise "simulated Open3 failure"
    end

    begin
      in_async do
        # The simulated raise propagates out of Shell.run. The
        # save/restore `ensure` must still run.
        assert_raises(RuntimeError) { Shell.run("true") }
      end
    ensure
      Open3.singleton_class.send(:remove_method, :capture3)
      Open3.define_singleton_method(:capture3, original)
    end

    observed[:restored] = Thread.report_on_exception

    assert_equal false, observed[:value],
      "Thread.report_on_exception must be false during the Open3.capture3 call"
    assert_equal pre, observed[:restored],
      "Thread.report_on_exception must be restored to the pre-call value " \
        "even when Open3.capture3 raises; pre=#{pre.inspect} restored=#{observed[:restored].inspect}"
  end
end
