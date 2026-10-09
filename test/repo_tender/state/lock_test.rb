# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class StateLockTest < Minitest::Test
  Lock = RepoTender::State::Lock

  def test_path_for_appends_dot_lock_suffix
    assert_equal "/tmp/foo/state.yaml.lock", Lock.path_for("/tmp/foo/state.yaml")
    assert_equal "/a/b/c.lock", Lock.path_for("/a/b/c")
  end

  def test_acquire_yields_and_returns_block_value
    Dir.mktmpdir("rt-lock-yield-") do |dir|
      state_file = File.join(dir, "state.yaml")
      result = Lock.acquire(state_file) { 42 }
      assert_equal 42, result
    end
  end

  def test_acquire_contends_from_second_fd_in_same_process
    # BSD flock (macOS): two File.open on the same path give independent
    # open file descriptions that contend. Verifies the in-process
    # simulation used in GA2/GA3 tests.
    Dir.mktmpdir("rt-lock-contend-") do |dir|
      state_file = File.join(dir, "state.yaml")
      inner_result = nil
      Lock.acquire(state_file) do
        # While the lock is held, a second fd on the same path must contend.
        fd2 = File.open(Lock.path_for(state_file), File::RDWR | File::CREAT)
        inner_result = fd2.flock(File::LOCK_EX | File::LOCK_NB)
        fd2.close
        :done
      end
      assert_equal false, inner_result,
        "second fd must NOT acquire lock while block is running"
    end
  end

  def test_acquire_returns_not_acquired_when_lock_is_held
    Dir.mktmpdir("rt-lock-held-") do |dir|
      state_file = File.join(dir, "state.yaml")
      lock_path = Lock.path_for(state_file)
      FileUtils.mkdir_p(File.dirname(lock_path))

      holder = File.open(lock_path, File::RDWR | File::CREAT)
      assert holder.flock(File::LOCK_EX | File::LOCK_NB),
        "precondition: holder must acquire the lock"

      begin
        block_ran = false
        result = Lock.acquire(state_file) { block_ran = true }
        assert_equal Lock::NOT_ACQUIRED, result,
          "acquire must return NOT_ACQUIRED when lock is already held"
        refute block_ran, "block must not run when lock is not acquired"
      ensure
        holder.flock(File::LOCK_UN)
        holder.close
      end
    end
  end

  def test_acquire_creates_directory_if_missing
    Dir.mktmpdir("rt-lock-mkdir-") do |dir|
      state_file = File.join(dir, "deep", "nested", "path", "state.yaml")
      refute File.exist?(File.dirname(Lock.path_for(state_file))),
        "precondition: directory must not exist"

      Lock.acquire(state_file) do
        assert File.exist?(File.dirname(Lock.path_for(state_file))),
          "acquire must create the lockfile directory"
      end
    end
  end

  def test_acquire_releases_lock_after_block_returns
    Dir.mktmpdir("rt-lock-release-") do |dir|
      state_file = File.join(dir, "state.yaml")
      Lock.acquire(state_file) { :done }

      lock_path = Lock.path_for(state_file)
      fd = File.open(lock_path, File::RDWR | File::CREAT)
      assert fd.flock(File::LOCK_EX | File::LOCK_NB),
        "lock must be released after the block returns normally"
      fd.flock(File::LOCK_UN)
      fd.close
    end
  end

  def test_acquire_releases_lock_after_raise_escapes_block
    Dir.mktmpdir("rt-lock-raise-") do |dir|
      state_file = File.join(dir, "state.yaml")
      assert_raises(RuntimeError) do
        Lock.acquire(state_file) { raise "boom" }
      end

      lock_path = Lock.path_for(state_file)
      fd = File.open(lock_path, File::RDWR | File::CREAT)
      assert fd.flock(File::LOCK_EX | File::LOCK_NB),
        "lock must be released after an exception escapes the block"
      fd.flock(File::LOCK_UN)
      fd.close
    end
  end

  def test_acquire_does_not_unlink_lockfile
    Dir.mktmpdir("rt-lock-persist-") do |dir|
      state_file = File.join(dir, "state.yaml")
      lock_path = Lock.path_for(state_file)

      Lock.acquire(state_file) { :done }

      assert File.exist?(lock_path),
        "lockfile must persist after release (never unlinked — deleting a flock'd file is a race)"
    end
  end

  def test_acquire_can_reacquire_after_previous_release
    Dir.mktmpdir("rt-lock-reacquire-") do |dir|
      state_file = File.join(dir, "state.yaml")
      Lock.acquire(state_file) { :first }
      result = Lock.acquire(state_file) { :second }
      assert_equal :second, result,
        "must be able to re-acquire the lock after a previous release"
    end
  end

  # CF12a: if `flock` *raises* (EINTR on a signal, ENOLCK on some
  # filesystems) instead of returning false, the fd must still be closed
  # — no leak. `File` is a collaborator, not the unit under test
  # (`State::Lock` is); same seam idiom as the GB1 store_test. A spy fd
  # records `#close` and raises from `#flock`.
  def test_acquire_closes_fd_when_flock_raises
    Dir.mktmpdir("rt-lock-flock-raise-") do |dir|
      state_file = File.join(dir, "state.yaml")
      closed = false
      spy = Object.new
      spy.define_singleton_method(:flock) { |*| raise Errno::ENOLCK }
      spy.define_singleton_method(:close) { closed = true }

      saved_open = File.method(:open)
      File.define_singleton_method(:open) { |*| spy }
      begin
        assert_raises(Errno::ENOLCK) do
          Lock.acquire(state_file) { flunk "must not yield when flock raises" }
        end
      ensure
        File.singleton_class.send(:remove_method, :open)
        File.define_singleton_method(:open, saved_open)
      end

      assert closed, "fd must be closed when flock raises (no leak)"
    end
  end
end
