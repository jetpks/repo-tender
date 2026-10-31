# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class StateYamlFileTest < Minitest::Test
  Backend = RepoTender::State::Backend
  YamlFile = RepoTender::State::YamlFile
  Store = RepoTender::State::Store
  Lock = RepoTender::State::Lock

  # ---- The abstract contract ----

  def test_backend_abstract_methods_raise_not_implemented
    backend = Backend.new
    assert_raises(NotImplementedError) { backend.load }
    assert_raises(NotImplementedError) { backend.save(Store::State.new) }
    assert_raises(NotImplementedError) { backend.with_exclusive_lock { :never } }
  end

  # ---- load ----

  def test_load_of_missing_file_returns_success_with_empty_state
    Dir.mktmpdir("rt-yaml-load-") do |dir|
      backend = YamlFile.new(state_file: File.join(dir, "state.yaml"))
      result = backend.load
      assert result.success?, result.failure.inspect
      assert_empty result.success.repos
      assert_empty result.success.orgs
    end
  end

  # ---- save ----

  def test_save_writes_a_loadable_state_file
    Dir.mktmpdir("rt-yaml-save-") do |dir|
      state_file = File.join(dir, "state.yaml")
      backend = YamlFile.new(state_file: state_file)
      state = Store::State.new(
        repos: {
          "github.com/ruby/ruby" => Store::Repo.new(
            default_branch: "trunk",
            last_fetch_at: Time.utc(2026, 10, 30, 9, 0, 0),
            last_synced_at: Time.utc(2026, 10, 30, 9, 0, 0),
            status: "clean"
          )
        },
        orgs: {
          "github.com/socketry" => Store::Org.new(
            last_listed_at: Time.utc(2026, 10, 30, 8, 0, 0),
            repo_count: 2
          )
        }
      )

      result = backend.save(state)
      assert result.success?, result.failure.inspect
      assert_equal state, result.success, "save returns the state it persisted"
      assert File.exist?(state_file), "save must persist to the state file"

      # Round-trip through the backend…
      reloaded = backend.load.success
      assert_equal "clean", reloaded.repos["github.com/ruby/ruby"].status
      assert_equal 2, reloaded.orgs["github.com/socketry"].repo_count

      # …and through State::Store directly — the CLI's status command
      # reads the very same file, so the formats must agree.
      direct = Store.load(state_file).success
      assert_equal "clean", direct.repos["github.com/ruby/ruby"].status
      assert_equal 2, direct.orgs["github.com/socketry"].repo_count
    end
  end

  def test_save_validates_before_writing
    Dir.mktmpdir("rt-yaml-invalid-") do |dir|
      state_file = File.join(dir, "state.yaml")
      backend = YamlFile.new(state_file: state_file)
      state = Store::State.new(
        repos: {
          "github.com/o/r" => Store::Repo.new(status: "bogus_status")
        },
        orgs: {}
      )
      result = backend.save(state)
      assert result.failure?, "State::Store's status enum validation must flow through the seam"
      refute File.exist?(state_file)
    end
  end

  # ---- with_exclusive_lock ----

  def test_with_exclusive_lock_returns_block_value
    Dir.mktmpdir("rt-yaml-lock-") do |dir|
      backend = YamlFile.new(state_file: File.join(dir, "state.yaml"))
      assert_equal 42, backend.with_exclusive_lock { 42 }
    end
  end

  def test_with_exclusive_lock_contended_returns_not_acquired
    # flock the sidecar lockfile from the test process itself — the
    # same in-process contention proof StateLockTest uses (two open
    # file descriptions on one path contend under BSD flock).
    Dir.mktmpdir("rt-yaml-contend-") do |dir|
      state_file = File.join(dir, "state.yaml")
      backend = YamlFile.new(state_file: state_file)
      lock_path = Lock.path_for(state_file)
      FileUtils.mkdir_p(File.dirname(lock_path))

      holder = File.open(lock_path, File::RDWR | File::CREAT)
      assert holder.flock(File::LOCK_EX | File::LOCK_NB),
        "precondition: holder must acquire the lock"
      begin
        block_ran = false
        result = backend.with_exclusive_lock { block_ran = true }
        assert_equal Lock::NOT_ACQUIRED, result,
          "contended lock must surface the NOT_ACQUIRED sentinel"
        refute block_ran, "block must not run when the lock is held elsewhere"
      ensure
        holder.flock(File::LOCK_UN)
        holder.close
      end
    end
  end

  def test_with_exclusive_lock_releases_after_the_block
    Dir.mktmpdir("rt-yaml-release-") do |dir|
      state_file = File.join(dir, "state.yaml")
      backend = YamlFile.new(state_file: state_file)
      backend.with_exclusive_lock { :done }

      lock_path = Lock.path_for(state_file)
      fd = File.open(lock_path, File::RDWR | File::CREAT)
      assert fd.flock(File::LOCK_EX | File::LOCK_NB),
        "lock must be released after the block returns"
      fd.flock(File::LOCK_UN)
      fd.close
    end
  end
end
