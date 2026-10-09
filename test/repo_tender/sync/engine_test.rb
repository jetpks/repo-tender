# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "time"

class SyncEngineTest < Minitest::Test
  include TestHelpers

  Engine = RepoTender::Sync::Engine
  Plan = RepoTender::Sync::RepoPlan
  Config = RepoTender::Config::Config
  RepoRef = RepoTender::Config::RepoRef
  OrgRef = RepoTender::Config::OrgRef
  SCMGit = RepoTender::SCM::Git
  StateStore = RepoTender::State::Store
  Status = RepoTender::SCM::Status

  # ---- Test doubles (dependency injection on the engine's collaborators) ----

  # A pure-Ruby stub of SCM::Client. All methods return canned values
  # so the engine's plan logic can be exercised without real git.
  class StubSCM
    attr_reader :status_calls, :fetch_calls, :current_branch_calls,
      :default_branch_calls, :last_fetch_calls, :switch_calls,
      :clone_calls, :fast_forward_calls
    attr_accessor :status_value, :current_branch_value, :default_branch_value,
      :last_fetch_value, :next_status_value, :fetch_value,
      :switch_value, :clone_value, :fast_forward_value, :raise_on

    def initialize(status_value:, current_branch_value: "trunk",
      default_branch_value: "trunk", last_fetch_value: nil,
      next_status_value: nil, fetch_value: :ok, fast_forward_value: 1,
      fail_paths: [], raise_on: nil)
      @status_value = status_value
      @current_branch_value = current_branch_value
      @default_branch_value = default_branch_value
      @last_fetch_value = last_fetch_value
      @next_status_value = next_status_value || status_value
      @fetch_value = fetch_value
      @switch_value = :ok
      @clone_value = :ok
      @fast_forward_value = fast_forward_value  # Integer: commits pulled (0 = up to date)
      @fail_paths = fail_paths.to_set
      @status_calls = 0
      @fetch_calls = 0
      @current_branch_calls = 0
      @default_branch_calls = 0
      @last_fetch_calls = 0
      @switch_calls = 0
      @clone_calls = 0
      @fast_forward_calls = 0
      @raise_on = raise_on
    end

    def status(path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: status failed"}) if @fail_paths.include?(path)
      @status_calls += 1
      Dry::Monads::Success((@status_calls == 1) ? @status_value : @next_status_value)
    end

    def current_branch(path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: current_branch failed"}) if @fail_paths.include?(path)
      @current_branch_calls += 1
      Dry::Monads::Success(@current_branch_value)
    end

    def default_branch(path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: default_branch failed"}) if @fail_paths.include?(path)
      @default_branch_calls += 1
      Dry::Monads::Success(@default_branch_value)
    end

    def last_fetch_at(path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: last_fetch_at failed"}) if @fail_paths.include?(path)
      @last_fetch_calls += 1
      Dry::Monads::Success(@last_fetch_value)
    end

    def fetch(path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: fetch failed"}) if @fail_paths.include?(path)
      @fetch_calls += 1
      Dry::Monads::Success(@fetch_value)
    end

    def switch(path, branch)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: switch failed"}) if @fail_paths.include?(path)
      @switch_calls += 1
      Dry::Monads::Success(@switch_value || branch)
    end

    def clone(url, path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: clone failed"}) if @fail_paths.include?(path)
      @clone_calls += 1
      Dry::Monads::Success(@clone_value || path)
    end

    def fast_forward(path, default_branch)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: fast_forward failed"}) if @fail_paths.include?(path)
      @fast_forward_calls += 1
      Dry::Monads::Success(@fast_forward_value)
    end

    def sync_empty(path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: sync_empty failed"}) if @fail_paths.include?(path)
      Dry::Monads::Success(:empty)
    end
  end

  # A SlowSCM for the G7 concurrency test. Increments a shared
  # counter inside a Mutex when work starts, decrements when work
  # ends. The engine's Async::Semaphore(concurrency) is the only
  # thing that should bound the in-flight count.
  class SlowSCM < SCMGit
    def initialize(delay: 0.05)
      super()
      @delay = delay
      @counter = 0
      @max_seen = 0
      @lock = Mutex.new
    end

    attr_reader :max_seen, :counter

    def with_lock(&block)
      @lock.synchronize(&block)
    end

    def clone(url, path)
      probe { :ok }
      Dry::Monads::Success(path)
    end

    def fetch(_path)
      probe { :ok }
      Dry::Monads::Success(:ok)
    end

    def fast_forward(_path, _default)
      probe { :ok }
      Dry::Monads::Success(:fast_forwarded)
    end

    private

    def probe
      with_lock do
        @counter += 1
        @max_seen = [@max_seen, @counter].max
      end
      sleep(@delay)
      with_lock { @counter -= 1 }
      yield
    end
  end

  # A Forge stub for the G10 tests.
  # check_authenticated returns Success by default; list_org uses response_for.
  class StubForge
    attr_reader :list_org_calls
    attr_accessor :response_for

    def initialize(response_for:, auth: :ok)
      @response_for = response_for
      @auth = auth
      @list_org_calls = 0
    end

    def check_authenticated
      if @auth == :ok
        Dry::Monads::Success(:authenticated)
      else
        Dry::Monads::Failure({reason: @auth.to_s})
      end
    end

    def list_org(org_ref)
      @list_org_calls += 1
      @response_for.call(org_ref)
    end
  end

  # SlowForge for the GS1 concurrency test.
  # list_org sleeps `delay` seconds and records max in-flight count.
  class SlowForge
    attr_reader :max_seen, :auth_calls, :list_org_calls

    def initialize(delay: 0.05, repos_per_org: 2)
      @delay = delay
      @repos_per_org = repos_per_org
      @counter = 0
      @max_seen = 0
      @lock = Mutex.new
      @auth_calls = 0
      @list_org_calls = 0
    end

    def check_authenticated
      @lock.synchronize { @auth_calls += 1 }
      Dry::Monads::Success(:authenticated)
    end

    def list_org(org_ref)
      @lock.synchronize do
        @counter += 1
        @max_seen = [@max_seen, @counter].max
        @list_org_calls += 1
      end
      sleep @delay
      @lock.synchronize { @counter -= 1 }
      repos = @repos_per_org.times.map do |i|
        RepoRef.new(host: org_ref.host, owner: org_ref.name, name: "repo#{i}")
      end
      Dry::Monads::Success(repos)
    end
  end

  # RecordingForge for the GS2 auth-once test.
  class RecordingForge
    attr_reader :auth_calls, :list_org_calls

    def initialize(repos_per_org: 1, auth_result: :ok)
      @auth_calls = 0
      @list_org_calls = 0
      @repos_per_org = repos_per_org
      @auth_result = auth_result
    end

    def check_authenticated
      @auth_calls += 1
      if @auth_result == :ok
        Dry::Monads::Success(:authenticated)
      else
        Dry::Monads::Failure({reason: @auth_result.to_s})
      end
    end

    def list_org(org_ref)
      @list_org_calls += 1
      repos = @repos_per_org.times.map do |i|
        RepoRef.new(host: org_ref.host, owner: org_ref.name, name: "repo#{i}")
      end
      Dry::Monads::Success(repos)
    end
  end

  # ---- Helpers ----

  def clean_status(branch: "trunk", upstream: "origin/trunk", ahead: 0, behind: 0)
    Status.new(clean: true, branch: branch, upstream: upstream, ahead: ahead, behind: behind)
  end

  def make_config(base_dir:, repos: [], orgs: [], refresh_interval: 3600, concurrency: 4)
    Config.new(
      base_dir: base_dir,
      refresh_interval: refresh_interval,
      concurrency: concurrency,
      repos: repos,
      orgs: orgs
    )
  end

  # Run the engine under a fresh XDG temp HOME so state.yaml lands
  # in a known location. Always creates a fresh temp base_dir (we
  # never want to write into the user's real ~/src/evergreen).
  # Yields (paths, base_dir, state_file).
  def with_engine_home
    Dir.mktmpdir("repo-tender-base-") do |base_dir|
      with_paths(base_dir: base_dir) do |env, paths|
        yield paths, base_dir, paths.state_file
      end
    end
  end

  # ===========================================================================
  # G1 — Clean + behind → fast-forward → status: clean
  # ===========================================================================
  def test_g1_clean_behind_fast_forwards_to_clean
    with_engine_home do |paths, base_dir, state_file|
      with_seeded_trunk_repo do |bare, clone|
        # Push a new commit from a second clone, then rewind the
        # original clone's trunk ref so it is one commit behind
        # origin/trunk.
        clone2 = File.join(File.dirname(clone), "clone2")
        system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone2,
          exception: true, out: File::NULL)
        Shell.run("git", "remote", "add", "origin", bare, chdir: clone2)
        Shell.run("git", "pull", "-q", "origin", "trunk", chdir: clone2)
        File.write(File.join(clone2, "remote.md"), "remote\n")
        Shell.run("git", "add", ".", chdir: clone2)
        Shell.run("git", "-c", "user.email=t@t.com", "-c", "user.name=T",
          "commit", "-qm", "remote commit", chdir: clone2)
        Shell.run("git", "push", "-q", "origin", "trunk", chdir: clone2)
        parent_sha = Shell.run("git", "rev-parse", "HEAD", chdir: clone).success.strip
        Shell.run("git", "update-ref", "refs/heads/trunk", parent_sha, chdir: clone)

        # Copy the clone into $BASE/github.com/ruby/ruby so the
        # engine can find it.
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"

        # State row exists with status: clean.
        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        refute_nil row
        assert_equal "clean", row.status

        # The new commit is on disk in the repo.
        assert File.exist?(File.join(repo_path, "remote.md")), "fast-forwarded commit missing"
      end
    end
  end

  # ===========================================================================
  # G2 — Fresh → skipped, no network
  # ===========================================================================
  def test_g2_fresh_repo_makes_no_network_call
    with_engine_home do |paths, base_dir, state_file|
      with_seeded_trunk_repo do |bare, clone|
        # Create a FETCH_HEAD with a recent mtime so the plan sees "fresh".
        Shell.run("git", "fetch", chdir: clone)
        # Place the repo under base_dir (preserving mtime so the
        # mtime_before / mtime_after comparison is meaningful).
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path, preserve: true)
        mtime_before = File.mtime(File.join(repo_path, ".git", "FETCH_HEAD"))

        config = make_config(base_dir: base_dir, repos: [ref], refresh_interval: 3600)
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"
        mtime_after = File.mtime(File.join(repo_path, ".git", "FETCH_HEAD"))
        assert_equal mtime_before, mtime_after,
          "FETCH_HEAD mtime changed on a fresh repo (engine performed a network call)"
      end
    end
  end

  # ===========================================================================
  # G3 — Dirty → byte-untouched + reported
  # ===========================================================================
  def test_g3_dirty_repo_left_byte_untouched_and_reported
    with_engine_home do |paths, base_dir, state_file|
      with_seeded_trunk_repo do |bare, clone|
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        # Capture the on-disk state before the run.
        File.read(File.join(repo_path, "README.md"))
        head_before = Shell.run("git", "rev-parse", "HEAD", chdir: repo_path).success.strip
        # Make it dirty: add a new file and a modification.
        File.write(File.join(repo_path, "README.md"), "modified-locally\n")
        File.write(File.join(repo_path, "local.txt"), "local\n")

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?

        # State row: status: dirty, no last_error.
        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        assert_equal "dirty", row.status
        assert_nil row.last_error

        # Working tree bytes are unchanged.
        assert_equal "modified-locally\n", File.read(File.join(repo_path, "README.md"))
        assert_equal "local\n", File.read(File.join(repo_path, "local.txt"))
        # HEAD is unchanged.
        head_after = Shell.run("git", "rev-parse", "HEAD", chdir: repo_path).success.strip
        assert_equal head_before, head_after, "HEAD changed on a dirty repo (no data loss)"
      end
    end
  end

  # ===========================================================================
  # G4 — Diverged → reported, no destruction
  # ===========================================================================
  def test_g4_diverged_repo_local_commits_intact
    with_engine_home do |paths, base_dir, state_file|
      with_seeded_trunk_repo do |bare, clone|
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        # Push a new commit from a second clone (so origin/trunk is
        # ahead of repo_path's local trunk).
        clone2 = File.join(File.dirname(clone), "clone2")
        system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone2,
          exception: true, out: File::NULL)
        Shell.run("git", "remote", "add", "origin", bare, chdir: clone2)
        Shell.run("git", "pull", "-q", "origin", "trunk", chdir: clone2)
        File.write(File.join(clone2, "remote.md"), "remote\n")
        Shell.run("git", "add", ".", chdir: clone2)
        Shell.run("git", "-c", "user.email=t@t.com", "-c", "user.name=T",
          "commit", "-qm", "remote commit", chdir: clone2)
        Shell.run("git", "push", "-q", "origin", "trunk", chdir: clone2)
        # NB: no explicit `git fetch` in repo_path — the plan's own
        # scm.fetch is what discovers the divergence. If we fetched
        # here, FETCH_HEAD would be "fresh" and the plan would skip
        # the rev-list probe (PRD §3.3 step 4 is before step 5).

        # Now make a local-only commit (ahead of origin).
        File.write(File.join(repo_path, "local.md"), "local\n")
        Shell.run("git", "add", ".", chdir: repo_path)
        Shell.run("git", "commit", "-qm", "local-only commit", chdir: repo_path)

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"

        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        assert_equal "diverged", row.status, "diverged repo should be reported"

        # The local commit is still in the log.
        log_out = Shell.run("git", "log", "--oneline", chdir: repo_path).success
        assert_includes log_out, "local-only commit"
        # The local file is still on disk.
        assert File.exist?(File.join(repo_path, "local.md"))
        # No reset --hard was performed.
        assert_equal "local\n", File.read(File.join(repo_path, "local.md"))
      end
    end
  end

  # ===========================================================================
  # G5 — Detached / wrong branch → switch only when clean
  # ===========================================================================
  def test_g5_wrong_branch_clean_switches_back_to_default
    with_engine_home do |paths, base_dir, state_file|
      with_seeded_trunk_repo do |bare, clone|
        Shell.run("git", "switch", "-c", "feature", chdir: clone)
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?

        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        assert_equal "clean", row.status
        assert_equal "trunk", row.default_branch

        # The local branch is back on trunk.
        current = Shell.run("git", "symbolic-ref", "--short", "HEAD", chdir: repo_path).success.strip
        assert_equal "trunk", current
      end
    end
  end

  def test_g5_wrong_branch_dirty_left_untouched_and_reported
    with_engine_home do |paths, base_dir, state_file|
      with_seeded_trunk_repo do |bare, clone|
        Shell.run("git", "switch", "-c", "feature", chdir: clone)
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        # Dirty the tree.
        File.write(File.join(repo_path, "dirty.txt"), "x")

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?

        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        assert_equal "wrong_branch", row.status, "dirty wrong-branch should be reported, not switched"
        assert_equal "trunk", row.default_branch

        # The local branch is still on feature (not switched).
        current = Shell.run("git", "symbolic-ref", "--short", "HEAD", chdir: repo_path).success.strip
        assert_equal "feature", current, "dirty wrong-branch was switched (engine guard failed)"
        # The dirty file is intact.
        assert_equal "x", File.read(File.join(repo_path, "dirty.txt"))
      end
    end
  end

  def test_g5_detached_dirty_left_untouched_and_reported
    with_engine_home do |paths, base_dir, state_file|
      with_seeded_trunk_repo do |bare, clone|
        head_sha = Shell.run("git", "rev-parse", "HEAD", chdir: clone).success.strip
        Shell.run("git", "checkout", "--detach", head_sha, chdir: clone)
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        File.write(File.join(repo_path, "dirty.txt"), "x")

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?

        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        assert_equal "detached", row.status

        # Still detached.
        current = Shell.run("git", "symbolic-ref", "--short", "HEAD", chdir: repo_path)
        assert current.failure?, "detached HEAD should still be detached"
        # Dirty file intact.
        assert_equal "x", File.read(File.join(repo_path, "dirty.txt"))
      end
    end
  end

  # ===========================================================================
  # G6 — Missing path → clone to $BASE/host/owner/repo
  # ===========================================================================
  def test_g6_missing_path_clones_to_derived_path
    with_engine_home do |paths, base_dir, state_file|
      Dir.mktmpdir("repo-tender-bare-") do |bare_dir|
        fixture = File.join(bare_dir, "fixture")
        FileUtils.cp_r(TestHelpers.seeded_trunk_template, fixture)
        bare = File.join(fixture, "bare.git")

        ref = RepoRef.new(host: "github.com", owner: "foo", name: "bar")
        expected_path = File.join(base_dir, "github.com", "foo", "bar")
        refute File.exist?(expected_path), "precondition: derived path should not exist"

        config = make_config(base_dir: base_dir, repos: [ref])
        url_builder = ->(_r) { "file://#{bare}" }
        result = Engine.new(url_builder: url_builder).call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"

        # The clone lands at exactly the derived path.
        assert File.directory?(expected_path), "clone did not land at #{expected_path}"
        assert File.directory?(File.join(expected_path, ".git")), "clone missing .git"

        # State row: status clean, default_branch trunk.
        state = StateStore.load(state_file).success
        row = state.repos["github.com/foo/bar"]
        refute_nil row
        assert_equal "clean", row.status
        assert_equal "trunk", row.default_branch
      end
    end
  end

  # ===========================================================================
  # G7 — Concurrency bound respected
  # ===========================================================================
  def test_g7_concurrency_two_bounds_in_flight_count
    Dir.mktmpdir("repo-tender-conc-") do |dir|
      base_dir = dir
      5.times do |i|
        FileUtils.mkdir_p(File.join(base_dir, "github.com", "owner", "repo#{i}"))
      end
      with_paths(base_dir: base_dir) do |env, paths|
        refs = (0...5).map { |i| RepoRef.new(host: "github.com", owner: "owner", name: "repo#{i}") }
        config = make_config(base_dir: base_dir, repos: refs, concurrency: 2)
        slow = SlowSCM.new(delay: 0.05)
        result = Engine.new(scm: slow).call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"
        assert_operator slow.max_seen, :<=, 2,
          "max in-flight count was #{slow.max_seen}, expected <= 2 (semaphore bound failed)"
        # All 5 still completed.
        state = StateStore.load(paths.state_file).success
        assert_equal 5, state.repos.size
      end
    end
  end

  # ===========================================================================
  # G8 — Per-repo failure isolated + state written
  # ===========================================================================
  def test_g8_per_repo_failure_isolated_and_state_written
    Dir.mktmpdir("repo-tender-iso-") do |dir|
      base_dir = dir
      2.times do |i|
        FileUtils.mkdir_p(File.join(base_dir, "github.com", "owner", "repo#{i}"))
      end
      with_paths(base_dir: base_dir) do |env, paths|
        refs = [
          RepoRef.new(host: "github.com", owner: "owner", name: "repo0"),
          RepoRef.new(host: "github.com", owner: "owner", name: "repo1")
        ]
        bad_path = File.join(base_dir, "github.com", "owner", "repo1")
        good_status = clean_status(branch: "trunk", ahead: 0, behind: 0)
        scm = StubSCM.new(
          status_value: good_status,
          current_branch_value: "trunk",
          default_branch_value: "trunk",
          last_fetch_value: nil,
          next_status_value: good_status,
          fail_paths: [bad_path]
        )
        config = make_config(base_dir: base_dir, repos: refs, concurrency: 2)
        result = Engine.new(scm: scm).call(config: config, paths: paths)
        assert result.success?, "engine should not abort on a per-repo failure: #{result.failure.inspect}"

        state = StateStore.load(paths.state_file).success
        assert_equal 2, state.repos.size, "every processed repo should have a state row"

        good_row = state.repos["github.com/owner/repo0"]
        refute_nil good_row
        assert_equal "clean", good_row.status

        bad_row = state.repos["github.com/owner/repo1"]
        refute_nil bad_row
        assert_equal "error", bad_row.status
        refute_nil bad_row.last_error
        assert_includes bad_row.last_error, "stub"
      end
    end
  end

  # G8 supplementary: an unhandled raise from the SCM is captured by
  # the engine's last-resort rescue and the run completes.
  def test_g8_unhandled_exception_in_scm_is_captured
    Dir.mktmpdir("repo-tender-raise-") do |dir|
      base_dir = dir
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "owner", "boom"))
      with_paths(base_dir: base_dir) do |env, paths|
        ref = RepoRef.new(host: "github.com", owner: "owner", name: "boom")
        scm = StubSCM.new(
          status_value: clean_status,
          raise_on: "stub: forced raise"
        )
        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new(scm: scm).call(config: config, paths: paths)
        assert result.success?, "engine should not abort on an unhandled raise: #{result.failure.inspect}"
        state = StateStore.load(paths.state_file).success
        row = state.repos["github.com/owner/boom"]
        refute_nil row
        assert_equal "error", row.status
        assert_includes row.last_error, "unhandled"
        assert_includes row.last_error, "forced raise"
      end
    end
  end

  # ===========================================================================
  # G9 — Idempotent (2nd run no network)
  # ===========================================================================
  def test_g9_idempotent_second_run_no_network
    with_engine_home do |paths, base_dir, state_file|
      with_seeded_trunk_repo do |bare, clone|
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        config = make_config(base_dir: base_dir, repos: [ref], refresh_interval: 3600)

        # First run: performs a fetch.
        result1 = Engine.new.call(config: config, paths: paths)
        assert result1.success?
        mtime_after_run1 = File.mtime(File.join(repo_path, ".git", "FETCH_HEAD"))

        # Second run: no network (FETCH_HEAD mtime unchanged).
        sleep 0.01  # ensure mtime resolution can detect a touch
        result2 = Engine.new.call(config: config, paths: paths)
        assert result2.success?
        mtime_after_run2 = File.mtime(File.join(repo_path, ".git", "FETCH_HEAD"))
        assert_equal mtime_after_run1, mtime_after_run2,
          "second run modified FETCH_HEAD (network call was performed)"

        # Second-run statuses match first-run statuses.
        state1 = StateStore.load(state_file).success
        row1 = state1.repos["github.com/ruby/ruby"]
        state2 = StateStore.load(state_file).success
        row2 = state2.repos["github.com/ruby/ruby"]
        assert_equal row1.status, row2.status
      end
    end
  end

  # ===========================================================================
  # G10 — Org expansion + resilience
  # ===========================================================================
  def test_g10_org_expansion_discovers_repos_and_writes_state
    Dir.mktmpdir("repo-tender-org-") do |dir|
      base_dir = dir
      2.times do |i|
        FileUtils.mkdir_p(File.join(base_dir, "github.com", "socketry", "lib#{i}"))
      end
      with_paths(base_dir: base_dir) do |env, paths|
        discovered = [
          RepoRef.new(host: "github.com", owner: "socketry", name: "lib0"),
          RepoRef.new(host: "github.com", owner: "socketry", name: "lib1")
        ]
        forge = StubForge.new(response_for: ->(_org) { Dry::Monads::Success(discovered) })
        org = OrgRef.new(host: "github.com", name: "socketry")
        config = make_config(base_dir: base_dir, orgs: [org], concurrency: 2)

        scm = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
          next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        result = Engine.new(scm: scm, forge: forge).call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"

        state = StateStore.load(paths.state_file).success
        assert_equal 2, state.repos.size, "both org-discovered repos should have state rows"
        assert state.repos["github.com/socketry/lib0"]
        assert state.repos["github.com/socketry/lib1"]
        # Org is recorded with repo_count.
        org_row = state.orgs["github.com/socketry"]
        refute_nil org_row
        assert_equal 2, org_row.repo_count
      end
    end
  end

  def test_g10_org_list_failure_is_resilient
    Dir.mktmpdir("repo-tender-orgfail-") do |dir|
      base_dir = dir
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "explicit", "rep"))
      with_paths(base_dir: base_dir) do |env, paths|
        forge = StubForge.new(
          response_for: ->(org) { Dry::Monads::Failure({org: org.name, reason: "gh not authenticated"}) }
        )
        org = OrgRef.new(host: "github.com", name: "someorg")
        explicit = RepoRef.new(host: "github.com", owner: "explicit", name: "rep")
        config = make_config(base_dir: base_dir, repos: [explicit], orgs: [org], concurrency: 2)

        scm = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
          next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        result = Engine.new(scm: scm, forge: forge).call(config: config, paths: paths)
        assert result.success?, "engine must not abort on an org-list failure: #{result.failure.inspect}"

        state = StateStore.load(paths.state_file).success
        # Explicit repo is processed.
        assert state.repos["github.com/explicit/rep"], "explicit repo missing from state"
        # The org's discovered repos are absent.
        refute state.repos["github.com/someorg/whatever"], "discovered repos should not be in state"
        # The org is recorded with repo_count 0.
        org_row = state.orgs["github.com/someorg"]
        refute_nil org_row
        assert_equal 0, org_row.repo_count
      end
    end
  end

  def test_g10_explicit_repo_wins_dedupe_against_org_discovered
    Dir.mktmpdir("repo-tender-dedupe-") do |dir|
      base_dir = dir
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "shared", "rep"))
      with_paths(base_dir: base_dir) do |env, paths|
        explicit = RepoRef.new(host: "github.com", owner: "shared", name: "rep")
        discovered = [explicit]  # same identity
        forge = StubForge.new(response_for: ->(_o) { Dry::Monads::Success(discovered) })
        org = OrgRef.new(host: "github.com", name: "shared")
        config = make_config(base_dir: base_dir, repos: [explicit], orgs: [org], concurrency: 1)

        scm = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
          next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        result = Engine.new(scm: scm, forge: forge).call(config: config, paths: paths)
        assert result.success?
        state = StateStore.load(paths.state_file).success
        # Only one row for the deduped repo.
        assert_equal 1, state.repos.size
        assert state.repos["github.com/shared/rep"]
        # Org recorded with repo_count 1 (the discovered count, not
        # the deduped count — this is the org's own discoverability,
        # not what the engine processed).
        assert_equal 1, state.orgs["github.com/shared"].repo_count
      end
    end
  end

  # ===========================================================================
  # G7 (CF3 part 2): an org-list Failure preserves prior good
  # `repo_count` + `last_listed_at` (NOT 0/nil) and sets `last_error`.
  # Previously-discovered repos remain present. The Slice 2 G10
  # behavior (run does not abort; failure recorded) stays intact.
  # ===========================================================================
  def test_g7_org_list_failure_preserves_prior_repo_count_and_records_error
    Dir.mktmpdir("repo-tender-cf3-") do |base_dir|
      # Two repos already discovered from a prior good run.
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "socketry", "lib0"))
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "socketry", "lib1"))
      with_paths(base_dir: base_dir) do |env, paths|
        org = OrgRef.new(host: "github.com", name: "socketry")

        # Run 1: forge lists 2 repos successfully. State captures
        # repo_count: 2, last_listed_at: now, last_error: nil.
        discovered = [
          RepoRef.new(host: "github.com", owner: "socketry", name: "lib0"),
          RepoRef.new(host: "github.com", owner: "socketry", name: "lib1")
        ]
        # Use a fixed clock for determinism.
        now1 = Time.utc(2026, 6, 13, 10, 0, 0)
        clock1 = -> { now1 }
        forge1 = StubForge.new(response_for: ->(_o) { Dry::Monads::Success(discovered) })
        scm1 = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
          next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        config1 = make_config(base_dir: base_dir, orgs: [org], concurrency: 2)

        result1 = Engine.new(scm: scm1, forge: forge1, clock: clock1).call(config: config1, paths: paths)
        assert result1.success?, "run 1 should succeed: #{result1.failure.inspect}"

        state_after_run1 = StateStore.load(paths.state_file).success
        org_row1 = state_after_run1.orgs["github.com/socketry"]
        refute_nil org_row1
        assert_equal 2, org_row1.repo_count, "run 1 should set repo_count=2"
        # `Org#to_h_compact` serializes `last_listed_at` as an
        # ISO-8601 string (see state/store.rb); the next load
        # re-reads it as a String. The engine received a Time
        # (`now1`) and wrote that value through; the on-disk form
        # is the string.
        assert_equal now1.iso8601, org_row1.last_listed_at
        assert_nil org_row1.last_error
        # Both repos in state.
        assert state_after_run1.repos["github.com/socketry/lib0"]
        assert state_after_run1.repos["github.com/socketry/lib1"]

        # Run 2: same config, but the forge now fails. The
        # previously-discovered repos are NOT in `config.repos`
        # (only the orgs track them); the engine will look them
        # up via prev state via the `prev.repos.dup` semantics
        # in build_new_state, and they remain present even
        # though no new SCM probe happens (no org-discovered
        # repos to process in this run).
        now2 = Time.utc(2026, 6, 13, 11, 0, 0)
        clock2 = -> { now2 }
        forge2 = StubForge.new(
          response_for: ->(o) { Dry::Monads::Failure({org: o.name, reason: "gh not authenticated"}) }
        )
        scm2 = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
          next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        config2 = make_config(base_dir: base_dir, orgs: [org], concurrency: 2)
        result2 = Engine.new(scm: scm2, forge: forge2, clock: clock2).call(config: config2, paths: paths)
        assert result2.success?, "run 2 should NOT abort on an org-list failure: #{result2.failure.inspect}"

        state_after_run2 = StateStore.load(paths.state_file).success
        org_row2 = state_after_run2.orgs["github.com/socketry"]
        refute_nil org_row2
        # CF3: prior good values are preserved, NOT clobbered to 0/nil.
        assert_equal 2, org_row2.repo_count, "CF3: repo_count must be preserved across transient failure"
        assert_equal now1.iso8601, org_row2.last_listed_at, "CF3: last_listed_at must be preserved across transient failure"
        # The failure is recorded (no longer nil).
        refute_nil org_row2.last_error
        assert_includes org_row2.last_error, "gh not authenticated"
        # Previously-discovered repos remain in state.
        assert state_after_run2.repos["github.com/socketry/lib0"], "lib0 vanished from state on transient failure"
        assert state_after_run2.repos["github.com/socketry/lib1"], "lib1 vanished from state on transient failure"
      end
    end
  end

  # Companion to G7: an org-list Failure on the FIRST run (no prior
  # state) records a last_error with repo_count: 0 and
  # last_listed_at: nil (no prior good to preserve).
  def test_g7_org_list_failure_on_first_run_records_error_with_zero_repo_count
    Dir.mktmpdir("repo-tender-cf3-first-") do |base_dir|
      with_paths(base_dir: base_dir) do |env, paths|
        org = OrgRef.new(host: "github.com", name: "socketry")
        forge = StubForge.new(
          response_for: ->(o) { Dry::Monads::Failure({org: o.name, reason: "rate limit"}) }
        )
        scm = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        config = make_config(base_dir: base_dir, orgs: [org], concurrency: 2)

        result = Engine.new(scm: scm, forge: forge).call(config: config, paths: paths)
        assert result.success?, "first-run org-list failure should NOT abort: #{result.failure.inspect}"

        state = StateStore.load(paths.state_file).success
        org_row = state.orgs["github.com/socketry"]
        refute_nil org_row
        assert_equal 0, org_row.repo_count
        assert_nil org_row.last_listed_at
        refute_nil org_row.last_error
        assert_includes org_row.last_error, "rate limit"
      end
    end
  end

  # ===========================================================================
  # prune: — build_new_state carries prev rows forward by default, so rows
  # for repos dropped from config accumulate forever. `prune: true` drops
  # them, but ONLY when the run saw the complete picture.
  # ===========================================================================

  # An org that stops listing a repo means the repo left the org, so its
  # row should go.
  def test_prune_drops_rows_for_repos_no_longer_listed_by_the_org
    Dir.mktmpdir("repo-tender-prune-") do |base_dir|
      with_paths(base_dir: base_dir) do |_env, paths|
        org = OrgRef.new(host: "github.com", name: "socketry")
        both = [
          RepoRef.new(host: "github.com", owner: "socketry", name: "lib0"),
          RepoRef.new(host: "github.com", owner: "socketry", name: "lib1")
        ]
        scm = -> {
          StubSCM.new(
            status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
            next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
          )
        }
        config = make_config(base_dir: base_dir, orgs: [org], concurrency: 2)

        # Run 1: org lists both.
        forge1 = StubForge.new(response_for: ->(_o) { Dry::Monads::Success(both) })
        r1 = Engine.new(scm: scm.call, forge: forge1).call(config: config, paths: paths, prune: true)
        assert r1.success?, "run 1 failed: #{r1.failure.inspect}"
        after1 = StateStore.load(paths.state_file).success
        assert after1.repos["github.com/socketry/lib0"]
        assert after1.repos["github.com/socketry/lib1"]

        # Run 2: org lists only lib0 — lib1 has left.
        forge2 = StubForge.new(response_for: ->(_o) { Dry::Monads::Success([both.first]) })
        r2 = Engine.new(scm: scm.call, forge: forge2).call(config: config, paths: paths, prune: true)
        assert r2.success?, "run 2 failed: #{r2.failure.inspect}"

        after2 = StateStore.load(paths.state_file).success
        assert after2.repos["github.com/socketry/lib0"], "still-listed repo was pruned"
        assert_nil after2.repos["github.com/socketry/lib1"],
          "row for a repo no longer listed by the org should have been pruned"
      end
    end
  end

  # The dangerous case: a transient forge outage empties `discovered`
  # through no fault of the config. Pruning on that would delete every
  # row for the whole org. The listings_complete guard must suppress it.
  def test_prune_is_suppressed_when_an_org_listing_fails
    Dir.mktmpdir("repo-tender-prune-outage-") do |base_dir|
      with_paths(base_dir: base_dir) do |_env, paths|
        org = OrgRef.new(host: "github.com", name: "socketry")
        discovered = [
          RepoRef.new(host: "github.com", owner: "socketry", name: "lib0"),
          RepoRef.new(host: "github.com", owner: "socketry", name: "lib1")
        ]
        scm = -> {
          StubSCM.new(
            status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
            next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
          )
        }
        config = make_config(base_dir: base_dir, orgs: [org], concurrency: 2)

        forge1 = StubForge.new(response_for: ->(_o) { Dry::Monads::Success(discovered) })
        r1 = Engine.new(scm: scm.call, forge: forge1).call(config: config, paths: paths, prune: true)
        assert r1.success?, "run 1 failed: #{r1.failure.inspect}"

        # Run 2: the forge is down. discovered is empty, so an unguarded
        # prune would wipe both rows.
        forge2 = StubForge.new(
          response_for: ->(o) { Dry::Monads::Failure({org: o.name, reason: "rate limit"}) }
        )
        r2 = Engine.new(scm: scm.call, forge: forge2).call(config: config, paths: paths, prune: true)
        assert r2.success?, "org-list failure must not abort: #{r2.failure.inspect}"

        after2 = StateStore.load(paths.state_file).success
        assert after2.repos["github.com/socketry/lib0"],
          "lib0 deleted by a prune that should have been suppressed by the org-list failure"
        assert after2.repos["github.com/socketry/lib1"],
          "lib1 deleted by a prune that should have been suppressed by the org-list failure"
      end
    end
  end

  # prune defaults to false: a caller that says nothing never loses rows.
  def test_prune_defaults_to_false_and_carries_unseen_rows_forward
    Dir.mktmpdir("repo-tender-prune-default-") do |base_dir|
      with_paths(base_dir: base_dir) do |_env, paths|
        seeded = StateStore::State.new(
          repos: {
            "github.com/gone/repo" => StateStore::Repo.new(
              default_branch: "trunk", last_fetch_at: nil,
              last_synced_at: "2000-01-01T00:00:00Z", status: "clean", last_error: nil
            )
          },
          orgs: {}
        )
        StateStore.write(paths.state_file, seeded)

        config = make_config(base_dir: base_dir, repos: [], orgs: [], concurrency: 2)
        result = Engine.new(scm: StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )).call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"
        assert_equal 0, result.success.processed

        after = StateStore.load(paths.state_file).success
        refute_nil after.repos["github.com/gone/repo"],
          "default prune: false must not delete rows the run did not see"
      end
    end
  end

  # ===========================================================================
  # Slice 6 G1 — DEFAULT_URL_BUILDER emits scp-like SSH form
  # (`git@<host>:<owner>/<name>.git`). The previous HTTPS form
  # made a missing-repo clone prompt for
  # `Username for 'https://github.com':`; SSH uses the user's
  # configured SSH keys with no interactive prompt. The url_builder
  # injection seam (G6) is unchanged — tests can still inject
  # `->(_r) { "file://#{bare}" }` for offline clones.
  # ===========================================================================
  def test_default_url_builder_emits_scp_like_ssh_form_for_github
    ref = RepoRef.new(host: "github.com", owner: "foo", name: "bar")
    assert_equal "git@github.com:foo/bar.git",
      Engine::DEFAULT_URL_BUILDER.call(ref)
  end

  def test_default_url_builder_emits_scp_like_ssh_form_for_ghe_style_host
    ref = RepoRef.new(host: "git.example.com", owner: "acme", name: "widget")
    assert_equal "git@git.example.com:acme/widget.git",
      Engine::DEFAULT_URL_BUILDER.call(ref)
  end

  def test_default_url_builder_does_not_contain_https
    ref = RepoRef.new(host: "github.com", owner: "foo", name: "bar")
    url = Engine::DEFAULT_URL_BUILDER.call(ref)
    refute_includes url, "https://", "default URL must not be HTTPS (no Username prompt)"
    refute_includes url, "Username", "default URL must not include 'Username'"
    assert url.start_with?("git@"), "default URL must start with 'git@' (scp-like SSH form)"
  end

  # ===========================================================================
  # Slice A (ui-foundation) — G2: default NullReporter produces byte-identical
  # state.yaml to an explicit NullReporter injection. Uses StubSCM + frozen
  # clock to eliminate timestamp variance between runs.
  # ===========================================================================

  def test_reporter_default_nullreporter_produces_byte_identical_state_yaml
    fixed_time = Time.utc(2026, 6, 13, 12, 0, 0)
    clock = -> { fixed_time }
    ref = RepoRef.new(host: "github.com", owner: "owner", name: "rep")
    good = clean_status(branch: "trunk", ahead: 0, behind: 0)

    content_default = Dir.mktmpdir("rt-g2a-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "github.com", "owner", "rep"))
      with_paths(base_dir: dir) do |_, paths|
        scm = StubSCM.new(status_value: good, default_branch_value: "trunk", last_fetch_value: nil)
        result = Engine.new(scm: scm, clock: clock).call(
          config: make_config(base_dir: dir, repos: [ref]), paths: paths
        )
        assert result.success?, "run failed: #{result.failure.inspect}"
        File.read(paths.state_file)
      end
    end

    content_explicit = Dir.mktmpdir("rt-g2b-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "github.com", "owner", "rep"))
      with_paths(base_dir: dir) do |_, paths|
        scm = StubSCM.new(status_value: good, default_branch_value: "trunk", last_fetch_value: nil)
        result = Engine.new(scm: scm, clock: clock, reporter: RepoTender::UI::NullReporter.new).call(
          config: make_config(base_dir: dir, repos: [ref]), paths: paths
        )
        assert result.success?, "run failed: #{result.failure.inspect}"
        File.read(paths.state_file)
      end
    end

    assert_equal content_default, content_explicit,
      "engine with default NullReporter must produce byte-identical state.yaml to explicit NullReporter"
  end

  # ===========================================================================
  # Slice A (ui-foundation) — G3: engine emits correct event sequence.
  # Recording reporter captures events; assertions on pairing/set by ref key,
  # not fixed cross-repo ordering (concurrent fibers interleave).
  # ===========================================================================

  class RecordingReporter
    attr_reader :events

    def initialize = @events = []

    def attach(task) = @events << [:attach]
    def listing_started(total:) = @events << [:listing_started, {total: total}]
    def org_listed(ref, count:) = @events << [:org_listed, ref, count]
    def listing_finished = @events << [:listing_finished]
    def run_started(total:) = @events << [:run_started, {total: total}]
    def repo_started(ref) = @events << [:repo_started, ref]
    def repo_phase(ref, phase) = @events << [:repo_phase, ref, phase]
    def repo_finished(ref, status, action:, commits: 0) = @events << [:repo_finished, ref, status, action, commits]
    def repo_failed(ref, error) = @events << [:repo_failed, ref, error]
    def run_finished(summary) = @events << [:run_finished, summary]
    def detach = @events << [:detach]
  end

  def test_g3_engine_emits_attach_run_started_repo_pairs_run_finished_detach
    reporter = RecordingReporter.new
    ref = RepoRef.new(host: "github.com", owner: "owner", name: "myrep")
    good = clean_status(branch: "trunk", ahead: 0, behind: 0)

    Dir.mktmpdir("rt-g3-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "github.com", "owner", "myrep"))
      with_paths(base_dir: dir) do |_, paths|
        scm = StubSCM.new(status_value: good, default_branch_value: "trunk", last_fetch_value: nil)
        result = Engine.new(scm: scm, reporter: reporter).call(
          config: make_config(base_dir: dir, repos: [ref]), paths: paths
        )
        assert result.success?

        evs = reporter.events
        # Phase order: attach → listing_started → listing_finished → run_started → … → run_finished → detach
        idx_attach = evs.index { |e| e.first == :attach }
        idx_listing_started = evs.index { |e| e.first == :listing_started }
        idx_listing_finished = evs.index { |e| e.first == :listing_finished }
        idx_run_started = evs.index { |e| e.first == :run_started }
        idx_run_finished = evs.index { |e| e.first == :run_finished }
        idx_detach = evs.index { |e| e.first == :detach }

        refute_nil idx_attach, "attach must be emitted"
        refute_nil idx_listing_started, "listing_started must be emitted"
        refute_nil idx_listing_finished, "listing_finished must be emitted"
        refute_nil idx_run_started, "run_started must be emitted"
        refute_nil idx_run_finished, "run_finished must be emitted"
        refute_nil idx_detach, "detach must be emitted"

        assert idx_attach < idx_listing_started, "attach must precede listing_started"
        assert idx_listing_started < idx_listing_finished, "listing_started must precede listing_finished"
        assert idx_listing_finished < idx_run_started, "listing_finished must precede run_started"
        assert idx_run_started < idx_run_finished, "run_started must precede run_finished"
        assert idx_run_finished < idx_detach, "run_finished must precede detach"

        run_started_ev = evs[idx_run_started]
        assert_equal 1, run_started_ev[1][:total]

        # attach + detach each appear exactly once
        assert_equal 1, evs.count { |e| e.first == :attach }
        assert_equal 1, evs.count { |e| e.first == :detach }
        # repo has a started + terminal pair
        key = "github.com/owner/myrep"
        assert_equal 1, evs.count { |e| e.first == :repo_started && e[1] == key }
        terminal = evs.count { |e| (e.first == :repo_finished || e.first == :repo_failed) && e[1] == key }
        assert_equal 1, terminal
      end
    end
  end

  def test_g3_repo_finished_status_matches_state_row
    reporter = RecordingReporter.new
    ref = RepoRef.new(host: "github.com", owner: "owner", name: "myrep")
    good = clean_status(branch: "trunk", ahead: 0, behind: 0)

    Dir.mktmpdir("rt-g3-match-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "github.com", "owner", "myrep"))
      with_paths(base_dir: dir) do |_, paths|
        scm = StubSCM.new(status_value: good, default_branch_value: "trunk", last_fetch_value: nil)
        result = Engine.new(scm: scm, reporter: reporter).call(
          config: make_config(base_dir: dir, repos: [ref]), paths: paths
        )
        assert result.success?

        key = "github.com/owner/myrep"
        ev = reporter.events.find { |e| e.first == :repo_finished && e[1] == key }
        refute_nil ev, "expected repo_finished event for #{key}"

        state = StateStore.load(paths.state_file).success
        assert_equal state.repos[key].status, ev[2],
          "reporter status must match state row status"
      end
    end
  end

  def test_g3_repo_that_raises_emits_repo_failed_and_run_completes
    reporter = RecordingReporter.new
    ref = RepoRef.new(host: "github.com", owner: "owner", name: "boom")

    Dir.mktmpdir("rt-g3-raise-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "github.com", "owner", "boom"))
      with_paths(base_dir: dir) do |_, paths|
        scm = StubSCM.new(
          status_value: clean_status,
          raise_on: RuntimeError.new("forced raise for g3")
        )
        result = Engine.new(scm: scm, reporter: reporter).call(
          config: make_config(base_dir: dir, repos: [ref]), paths: paths
        )
        assert result.success?, "engine must complete even when a repo raises"

        key = "github.com/owner/boom"
        # repo_failed must be emitted (not repo_finished)
        assert reporter.events.any? { |e| e.first == :repo_failed && e[1] == key },
          "expected repo_failed for #{key} after unhandled raise"
        refute reporter.events.any? { |e| e.first == :repo_finished && e[1] == key },
          "expected no repo_finished for #{key} after unhandled raise"
        # run still completes with run_finished + detach
        assert reporter.events.any? { |e| e.first == :run_finished }
        assert reporter.events.any? { |e| e.first == :detach }
      end
    end
  end

  def test_g3_four_scenario_run_emits_correct_pairs
    # {fast-forward, dirty, missing-clone, diverged} — all 4 scenarios.
    # Uses real git repos to verify end-to-end event+state parity.
    reporter = RecordingReporter.new

    Dir.mktmpdir("rt-g3-4s-bares-") do |bares|
      Dir.mktmpdir("rt-g3-4s-base-") do |base_dir|
        with_paths(base_dir: base_dir) do |_env, paths|
          refs = []

          # ---- Repo A: clean+behind → fast-forward (status: clean) ----
          bare_a = File.join(bares, "a.git")
          system("git", "init", "-b", "trunk", "--bare", bare_a, exception: true, out: File::NULL)
          work_a = File.join(bares, "work_a")
          system("git", "-c", "init.defaultBranch=trunk", "init", "-q", work_a, exception: true, out: File::NULL)
          in_async do
            Shell.run("git", "remote", "add", "origin", bare_a, chdir: work_a)
            File.write(File.join(work_a, "README.md"), "a\n")
            Shell.run("git", "add", ".", chdir: work_a)
            Shell.run("git", "-c", "user.email=t@t.com", "-c", "user.name=T",
              "commit", "-qm", "init", chdir: work_a)
            Shell.run("git", "push", "-q", "-u", "origin", "trunk", chdir: work_a)
          end
          # Push a second commit from a second clone, leaving work_a one behind
          work_a2 = File.join(bares, "work_a2")
          system("git", "-c", "init.defaultBranch=trunk", "init", "-q", work_a2, exception: true, out: File::NULL)
          in_async do
            Shell.run("git", "remote", "add", "origin", bare_a, chdir: work_a2)
            Shell.run("git", "pull", "-q", "origin", "trunk", chdir: work_a2)
            File.write(File.join(work_a2, "extra.md"), "extra\n")
            Shell.run("git", "add", ".", chdir: work_a2)
            Shell.run("git", "-c", "user.email=t@t.com", "-c", "user.name=T",
              "commit", "-qm", "extra", chdir: work_a2)
            Shell.run("git", "push", "-q", "origin", "trunk", chdir: work_a2)
            # Rewind work_a's local branch to be behind
            parent_sha = Shell.run("git", "rev-parse", "HEAD~1", chdir: work_a2).success.strip
            Shell.run("git", "update-ref", "refs/heads/trunk", parent_sha, chdir: work_a)
          end
          ref_a = RepoRef.new(host: "github.com", owner: "o", name: "repo-a")
          path_a = File.join(base_dir, "github.com", "o", "repo-a")
          FileUtils.mkdir_p(File.dirname(path_a))
          FileUtils.cp_r(work_a, path_a)
          refs << ref_a

          # ---- Repo B: dirty (status: dirty) ----
          bare_b = File.join(bares, "b.git")
          system("git", "init", "-b", "trunk", "--bare", bare_b, exception: true, out: File::NULL)
          work_b = File.join(bares, "work_b")
          system("git", "-c", "init.defaultBranch=trunk", "init", "-q", work_b, exception: true, out: File::NULL)
          in_async do
            Shell.run("git", "remote", "add", "origin", bare_b, chdir: work_b)
            File.write(File.join(work_b, "README.md"), "b\n")
            Shell.run("git", "add", ".", chdir: work_b)
            Shell.run("git", "-c", "user.email=t@t.com", "-c", "user.name=T",
              "commit", "-qm", "init", chdir: work_b)
            Shell.run("git", "push", "-q", "-u", "origin", "trunk", chdir: work_b)
          end
          ref_b = RepoRef.new(host: "github.com", owner: "o", name: "repo-b")
          path_b = File.join(base_dir, "github.com", "o", "repo-b")
          FileUtils.mkdir_p(File.dirname(path_b))
          FileUtils.cp_r(work_b, path_b)
          File.write(File.join(path_b, "dirty.txt"), "x")  # make it dirty
          refs << ref_b

          # ---- Repo C: missing path → clone (status: clean) ----
          bare_c = File.join(bares, "c.git")
          system("git", "init", "-b", "trunk", "--bare", bare_c, exception: true, out: File::NULL)
          work_c = File.join(bares, "work_c")
          system("git", "-c", "init.defaultBranch=trunk", "init", "-q", work_c, exception: true, out: File::NULL)
          in_async do
            Shell.run("git", "remote", "add", "origin", bare_c, chdir: work_c)
            File.write(File.join(work_c, "README.md"), "c\n")
            Shell.run("git", "add", ".", chdir: work_c)
            Shell.run("git", "-c", "user.email=t@t.com", "-c", "user.name=T",
              "commit", "-qm", "init", chdir: work_c)
            Shell.run("git", "push", "-q", "-u", "origin", "trunk", chdir: work_c)
          end
          ref_c = RepoRef.new(host: "github.com", owner: "o", name: "repo-c")
          # Do NOT copy work_c to base_dir — engine will clone it
          refs << ref_c

          # ---- Repo D: diverged ----
          bare_d = File.join(bares, "d.git")
          system("git", "init", "-b", "trunk", "--bare", bare_d, exception: true, out: File::NULL)
          work_d = File.join(bares, "work_d")
          system("git", "-c", "init.defaultBranch=trunk", "init", "-q", work_d, exception: true, out: File::NULL)
          in_async do
            Shell.run("git", "remote", "add", "origin", bare_d, chdir: work_d)
            File.write(File.join(work_d, "README.md"), "d\n")
            Shell.run("git", "add", ".", chdir: work_d)
            Shell.run("git", "-c", "user.email=t@t.com", "-c", "user.name=T",
              "commit", "-qm", "init", chdir: work_d)
            Shell.run("git", "push", "-q", "-u", "origin", "trunk", chdir: work_d)
          end
          # Push a remote commit
          work_d2 = File.join(bares, "work_d2")
          system("git", "-c", "init.defaultBranch=trunk", "init", "-q", work_d2, exception: true, out: File::NULL)
          in_async do
            Shell.run("git", "remote", "add", "origin", bare_d, chdir: work_d2)
            Shell.run("git", "pull", "-q", "origin", "trunk", chdir: work_d2)
            File.write(File.join(work_d2, "remote.md"), "remote\n")
            Shell.run("git", "add", ".", chdir: work_d2)
            Shell.run("git", "-c", "user.email=t@t.com", "-c", "user.name=T",
              "commit", "-qm", "remote", chdir: work_d2)
            Shell.run("git", "push", "-q", "origin", "trunk", chdir: work_d2)
          end
          ref_d = RepoRef.new(host: "github.com", owner: "o", name: "repo-d")
          path_d = File.join(base_dir, "github.com", "o", "repo-d")
          FileUtils.mkdir_p(File.dirname(path_d))
          FileUtils.cp_r(work_d, path_d)
          # Add a local commit to make it diverged
          in_async do
            File.write(File.join(path_d, "local.md"), "local\n")
            Shell.run("git", "add", ".", chdir: path_d)
            Shell.run("git", "commit", "-qm", "local", chdir: path_d)
          end
          refs << ref_d

          url_builder = lambda { |r|
            bare = File.join(bares, "#{r.name.split("-").last}.git")
            "file://#{bare}"
          }

          config = make_config(base_dir: base_dir, repos: refs, concurrency: 4)
          result = Engine.new(reporter: reporter, url_builder: url_builder).call(
            config: config, paths: paths
          )
          assert result.success?, "engine failed: #{result.failure.inspect}"

          state = StateStore.load(paths.state_file).success
          evs = reporter.events

          # Phase order: attach → listing_started → listing_finished → run_started → … → run_finished → detach
          idx_attach = evs.index { |e| e.first == :attach }
          idx_listing_started = evs.index { |e| e.first == :listing_started }
          idx_listing_finished = evs.index { |e| e.first == :listing_finished }
          idx_run_started = evs.index { |e| e.first == :run_started }
          idx_run_finished = evs.index { |e| e.first == :run_finished }
          idx_detach = evs.index { |e| e.first == :detach }

          assert idx_attach < idx_listing_started, "attach before listing_started"
          assert idx_listing_started < idx_listing_finished, "listing_started before listing_finished"
          assert idx_listing_finished < idx_run_started, "listing_finished before run_started"
          assert idx_run_started < idx_run_finished, "run_started before run_finished"
          assert idx_run_finished < idx_detach, "run_finished before detach"
          assert_equal 4, evs[idx_run_started][1][:total]

          # Every repo has exactly one started + one terminal pair; terminal status matches state
          refs.each do |ref|
            key = "github.com/o/#{ref.name}"
            n_started = evs.count { |e| e.first == :repo_started && e[1] == key }
            assert_equal 1, n_started, "#{key}: expected 1 repo_started, got #{n_started}"

            n_terminal = evs.count { |e|
              (e.first == :repo_finished || e.first == :repo_failed) && e[1] == key
            }
            assert_equal 1, n_terminal, "#{key}: expected 1 terminal event, got #{n_terminal}"

            finished_ev = evs.find { |e| e.first == :repo_finished && e[1] == key }
            if finished_ev
              assert_equal state.repos[key]&.status, finished_ev[2],
                "#{key}: reporter status must match state row"
            end
          end
        end
      end
    end
  end

  # ===========================================================================
  # GS1 — Org expansion is CONCURRENT (SlowForge + max-in-flight assertion)
  # ===========================================================================
  def test_gs1_org_expansion_is_concurrent
    n_orgs = 4
    delay = 0.05
    slow_forge = SlowForge.new(delay: delay, repos_per_org: 1)
    orgs = n_orgs.times.map { |i| OrgRef.new(host: "github.com", name: "org#{i}") }

    Dir.mktmpdir("rt-gs1-") do |base_dir|
      with_paths(base_dir: base_dir) do |_, paths|
        config = make_config(base_dir: base_dir, orgs: orgs, concurrency: n_orgs)
        scm = StubSCM.new(status_value: clean_status)

        t0 = Time.now
        result = Engine.new(scm: scm, forge: slow_forge).call(config: config, paths: paths)
        elapsed = Time.now - t0

        assert result.success?, "engine failed: #{result.failure.inspect}"
        assert slow_forge.max_seen > 1,
          "max in-flight list_org calls must be > 1 (got #{slow_forge.max_seen}); org expansion is still sequential"
        # Wall-time must be less than (N-1)*delay — proving fan-out
        assert elapsed < (n_orgs - 1) * delay,
          "wall-time #{elapsed.round(2)}s must be < #{((n_orgs - 1) * delay).round(2)}s (sequential would be #{(n_orgs * delay).round(2)}s)"
      end
    end
  end

  # ===========================================================================
  # GS2 — check_authenticated called EXACTLY ONCE regardless of org count;
  #        list_org does no auth; auth Failure records all orgs failed (CF3)
  #        without crash.
  # ===========================================================================
  def test_gs2_check_authenticated_called_exactly_once_for_five_orgs
    forge = RecordingForge.new(repos_per_org: 0)
    orgs = 5.times.map { |i| OrgRef.new(host: "github.com", name: "org#{i}") }

    Dir.mktmpdir("rt-gs2-") do |base_dir|
      with_paths(base_dir: base_dir) do |_, paths|
        config = make_config(base_dir: base_dir, orgs: orgs, concurrency: 4)
        result = Engine.new(forge: forge).call(config: config, paths: paths)
        assert result.success?
        assert_equal 1, forge.auth_calls,
          "check_authenticated must be invoked exactly once (got #{forge.auth_calls})"
        assert_equal 5, forge.list_org_calls,
          "list_org must be called once per org when auth succeeds (got #{forge.list_org_calls})"
      end
    end
  end

  def test_gs2_auth_failure_records_all_orgs_failed_no_list_org_called
    forge = RecordingForge.new(repos_per_org: 1, auth_result: "gh not authenticated")
    org = OrgRef.new(host: "github.com", name: "someorg")

    Dir.mktmpdir("rt-gs2-auth-") do |base_dir|
      # Seed a repo that was listed in a prior successful run
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "explicit", "rep"))
      with_paths(base_dir: base_dir) do |_, paths|
        explicit = RepoRef.new(host: "github.com", owner: "explicit", name: "rep")
        config = make_config(base_dir: base_dir, repos: [explicit], orgs: [org], concurrency: 2)
        scm = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
          next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        result = Engine.new(scm: scm, forge: forge).call(config: config, paths: paths)
        assert result.success?, "engine must not abort on auth failure: #{result.failure.inspect}"
        assert_equal 1, forge.auth_calls, "check_authenticated must be called exactly once"
        assert_equal 0, forge.list_org_calls, "list_org must NOT be called on auth failure"

        state = StateStore.load(paths.state_file).success
        org_row = state.orgs["github.com/someorg"]
        refute_nil org_row
        refute_nil org_row.last_error, "org must have last_error recorded on auth failure"
        assert_includes org_row.last_error, "gh not authenticated"
        # Explicit repo still processed
        assert state.repos["github.com/explicit/rep"], "explicit repo must be processed even on org auth failure"
      end
    end
  end

  # ===========================================================================
  # GS3 — discovered repo set is order-independent identical to sequential
  #        baseline; explicit-wins dedupe unchanged by concurrency
  # ===========================================================================
  def test_gs3_concurrent_expansion_discovers_same_set_as_sequential
    orgs = 3.times.map { |i| OrgRef.new(host: "github.com", name: "org#{i}") }
    expected_repos = orgs.each_with_index.flat_map do |org, i|
      [RepoRef.new(host: "github.com", owner: org.name, name: "repo#{i}")]
    end

    forge = StubForge.new(response_for: lambda { |org_ref|
      idx = org_ref.name.delete_prefix("org").to_i
      Dry::Monads::Success([RepoRef.new(host: "github.com", owner: org_ref.name, name: "repo#{idx}")])
    })

    Dir.mktmpdir("rt-gs3-") do |base_dir|
      with_paths(base_dir: base_dir) do |_, paths|
        config = make_config(base_dir: base_dir, orgs: orgs, concurrency: 4)
        scm = StubSCM.new(status_value: clean_status)
        result = Engine.new(scm: scm, forge: forge).call(config: config, paths: paths)
        assert result.success?
        state = StateStore.load(paths.state_file).success
        discovered_keys = state.repos.keys.to_set
        expected_keys = expected_repos.map { |r| "#{r.host}/#{r.owner}/#{r.name}" }.to_set
        assert_equal expected_keys, discovered_keys,
          "concurrent expansion must discover the same repo set as sequential"
      end
    end
  end

  # ===========================================================================
  # GS4 — Listing events in phase order (with recording reporter over a run
  #        that has real orgs)
  # ===========================================================================
  def test_gs4_listing_events_in_phase_order
    reporter = RecordingReporter.new
    org = OrgRef.new(host: "github.com", name: "socketry")
    discovered = [RepoRef.new(host: "github.com", owner: "socketry", name: "lib0")]
    forge = StubForge.new(response_for: ->(_o) { Dry::Monads::Success(discovered) })

    Dir.mktmpdir("rt-gs4-") do |base_dir|
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "socketry", "lib0"))
      with_paths(base_dir: base_dir) do |_, paths|
        scm = StubSCM.new(status_value: clean_status(branch: "trunk", ahead: 0, behind: 0))
        config = make_config(base_dir: base_dir, orgs: [org], concurrency: 2)
        result = Engine.new(scm: scm, forge: forge, reporter: reporter).call(config: config, paths: paths)
        assert result.success?

        evs = reporter.events
        names = evs.map(&:first)

        idx_attach = names.index(:attach)
        idx_listing_started = names.index(:listing_started)
        idx_listing_finished = names.index(:listing_finished)
        idx_run_started = names.index(:run_started)
        idx_run_finished = names.index(:run_finished)
        idx_detach = names.index(:detach)

        # Phase order
        assert idx_attach < idx_listing_started, "attach before listing_started"
        assert idx_listing_started < idx_listing_finished, "listing_started before listing_finished"
        assert idx_listing_finished < idx_run_started, "listing_finished before run_started"
        assert idx_run_started < idx_run_finished, "run_started before run_finished"
        assert idx_run_finished < idx_detach, "run_finished before detach"

        # listing_started carries org count
        ls_ev = evs[idx_listing_started]
        assert_equal 1, ls_ev[1][:total], "listing_started total must equal org count"

        # exactly one org_listed event per org
        org_listed_evs = evs.select { |e| e.first == :org_listed }
        assert_equal 1, org_listed_evs.size, "expected 1 org_listed event"
        assert_equal "socketry", org_listed_evs.first[1].name
        assert_equal 1, org_listed_evs.first[2], "org_listed count must equal discovered repos"

        # run_started total equals discovered repo count (after dedupe)
        assert_equal 1, evs[idx_run_started][1][:total]
      end
    end
  end

  def test_gs4_listing_started_with_zero_orgs_emits_no_org_listed
    reporter = RecordingReporter.new
    ref = RepoRef.new(host: "github.com", owner: "owner", name: "rep")

    Dir.mktmpdir("rt-gs4-zero-") do |base_dir|
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "owner", "rep"))
      with_paths(base_dir: base_dir) do |_, paths|
        scm = StubSCM.new(status_value: clean_status(branch: "trunk", ahead: 0, behind: 0))
        config = make_config(base_dir: base_dir, repos: [ref], orgs: [], concurrency: 2)
        result = Engine.new(scm: scm, reporter: reporter).call(config: config, paths: paths)
        assert result.success?

        evs = reporter.events
        assert evs.any? { |e| e.first == :listing_started && e[1][:total] == 0 }
        assert evs.any? { |e| e.first == :listing_finished }
        assert_equal 0, evs.count { |e| e.first == :org_listed }
      end
    end
  end

  # ===========================================================================
  # G9.1 — A raising list_org is isolated; run completes and writes state (CF9).
  # Mirrors the repo-sweep G8 guarantee. CF3: prior repo_count/last_listed_at
  # preserved for the raising org when a prev row exists.
  # ===========================================================================
  def test_g9_1_raising_list_org_isolated_run_completes_state_written
    prev_listed_at = Time.utc(2026, 1, 1, 0, 0, 0)

    org_raising = OrgRef.new(host: "github.com", name: "raising-org")
    org_ok1 = OrgRef.new(host: "github.com", name: "ok-org1")
    org_ok2 = OrgRef.new(host: "github.com", name: "ok-org2")

    ok_repo1 = RepoRef.new(host: "github.com", owner: "ok-org1", name: "lib")
    ok_repo2 = RepoRef.new(host: "github.com", owner: "ok-org2", name: "lib")

    forge = StubForge.new(response_for: lambda { |org_ref|
      raise "simulated parse error in list_org" if org_ref.name == "raising-org"
      repos = case org_ref.name
      when "ok-org1" then [ok_repo1]
      when "ok-org2" then [ok_repo2]
      else []
      end
      Dry::Monads::Success(repos)
    })

    Dir.mktmpdir("rt-g9-1-") do |base_dir|
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "ok-org1", "lib"))
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "ok-org2", "lib"))

      with_paths(base_dir: base_dir) do |_, paths|
        # Seed prev state with an existing row for the raising org (CF3).
        prev_state = StateStore::State.new(
          repos: {},
          orgs: {
            "github.com/raising-org" => StateStore::Org.new(
              last_listed_at: prev_listed_at.iso8601,
              repo_count: 5,
              last_error: nil
            )
          }
        )
        StateStore.write(paths.state_file, prev_state)

        scm = StubSCM.new(status_value: clean_status(branch: "trunk", ahead: 0, behind: 0))
        config = make_config(
          base_dir: base_dir,
          orgs: [org_raising, org_ok1, org_ok2],
          concurrency: 3
        )

        result = Engine.new(scm: scm, forge: forge).call(config: config, paths: paths)
        assert result.success?,
          "Engine#call must return Success even when list_org raises: #{result.failure.inspect}"

        state = StateStore.load(paths.state_file).success

        # Raising org is recorded with last_error.
        raising_row = state.orgs["github.com/raising-org"]
        refute_nil raising_row, "raising org must have a state row"
        refute_nil raising_row.last_error, "raising org must have last_error set"
        assert_includes raising_row.last_error, "unhandled:"
        assert_includes raising_row.last_error, "RuntimeError"
        assert_includes raising_row.last_error, "simulated parse error in list_org"

        # CF3: prior repo_count and last_listed_at preserved.
        assert_equal 5, raising_row.repo_count,
          "CF3: prior repo_count must be preserved when list_org raises"
        assert_equal prev_listed_at.iso8601, raising_row.last_listed_at,
          "CF3: prior last_listed_at must be preserved when list_org raises"

        # Other orgs are listed normally.
        ok1_row = state.orgs["github.com/ok-org1"]
        refute_nil ok1_row, "ok-org1 must be recorded"
        assert_equal 1, ok1_row.repo_count
        assert_nil ok1_row.last_error

        ok2_row = state.orgs["github.com/ok-org2"]
        refute_nil ok2_row, "ok-org2 must be recorded"
        assert_equal 1, ok2_row.repo_count

        # Discovered repos from ok orgs are processed and in state.
        assert state.repos["github.com/ok-org1/lib"], "ok-org1/lib must be in state"
        assert state.repos["github.com/ok-org2/lib"], "ok-org2/lib must be in state"

        # state.yaml IS written (no-data-loss invariant).
        assert File.exist?(paths.state_file), "state.yaml must be written even when list_org raises"
      end
    end
  end

  # G9.1 (no-prev-row): raising list_org on first run records last_error with
  # zero repo_count and nil last_listed_at (nothing to preserve — CF3 vacuous).
  def test_g9_1_raising_list_org_first_run_records_error_with_zero_repo_count
    org = OrgRef.new(host: "github.com", name: "boom-org")
    forge = StubForge.new(response_for: lambda { |_org_ref|
      raise ArgumentError, "nil.split (schema violation)"
    })

    Dir.mktmpdir("rt-g9-1b-") do |base_dir|
      with_paths(base_dir: base_dir) do |_, paths|
        config = make_config(base_dir: base_dir, orgs: [org], concurrency: 1)
        result = Engine.new(forge: forge).call(config: config, paths: paths)
        assert result.success?,
          "Engine#call must return Success on first-run list_org raise: #{result.failure.inspect}"

        state = StateStore.load(paths.state_file).success
        row = state.orgs["github.com/boom-org"]
        refute_nil row
        assert_equal 0, row.repo_count
        assert_nil row.last_listed_at
        refute_nil row.last_error
        assert_includes row.last_error, "unhandled:"
        assert_includes row.last_error, "ArgumentError"
        assert_includes row.last_error, "nil.split"
      end
    end
  end

  # ===========================================================================
  # G9.2 — Teardown runs even on an escaping raise (Part B ensure-guard).
  # Injection: reporter#listing_started raises, escaping the attach…detach span
  # in Engine#call before Part A's org-fiber rescue can catch anything.
  # The ensure guard must still invoke @reporter.detach exactly once.
  # ===========================================================================

  class RaisingOnListingStartedReporter
    attr_reader :events

    def initialize = @events = []

    def attach(task) = @events << [:attach]
    def listing_started(total:) = raise("injected raise in listing_started (G9.2)")
    def org_listed(ref, count:) = @events << [:org_listed]
    def listing_finished = @events << [:listing_finished]
    def run_started(total:) = @events << [:run_started]
    def repo_started(ref) = @events << [:repo_started]
    def repo_phase(ref, phase) = @events << [:repo_phase]
    def repo_finished(ref, status) = @events << [:repo_finished]
    def repo_failed(ref, error) = @events << [:repo_failed]
    def run_finished(summary) = @events << [:run_finished]
    def detach = @events << [:detach]
  end

  def test_g9_2_ensure_detach_runs_on_escaping_raise_from_listing_started
    # Injection: RaisingOnListingStartedReporter#listing_started raises,
    # escaping the attach…detach span. Engine#call propagates the raise;
    # the ensure guard must still call detach exactly once.
    reporter = RaisingOnListingStartedReporter.new
    org = OrgRef.new(host: "github.com", name: "socketry")
    forge = RecordingForge.new(repos_per_org: 0)

    Dir.mktmpdir("rt-g9-2-") do |base_dir|
      with_paths(base_dir: base_dir) do |_, paths|
        config = make_config(base_dir: base_dir, orgs: [org], concurrency: 1)

        assert_raises(RuntimeError) do
          Engine.new(forge: forge, reporter: reporter).call(config: config, paths: paths)
        end

        assert_equal 1, reporter.events.count { |e| e.first == :attach },
          "attach must be called exactly once"
        assert_equal 1, reporter.events.count { |e| e.first == :detach },
          "detach must be called exactly once even when an exception escapes the attach…detach span"
      end
    end
  end

  # ===========================================================================
  # GA2 — No clobber under overlap (CF10 core invariant)
  # Pre-seed state.yaml; hold lock from an independent fd (simulates an
  # in-flight run in the same process); call Engine#call; assert:
  # (a) state.yaml bytes unchanged, (b) call returns without raising,
  # (c) distinguishable "skipped" signal (bytes unchanged + Success).
  # Then release the lock and call again: engine proceeds, writes, and
  # prior rows are preserved (CF3 intact).
  # ===========================================================================
  def test_ga2_no_clobber_under_overlap
    Dir.mktmpdir("rt-ga2-") do |base_dir|
      with_paths(base_dir: base_dir) do |_, paths|
        state_file = paths.state_file
        lock_path = RepoTender::State::Lock.path_for(state_file)

        # Pre-seed state.yaml with a prior row.
        prior_key = "github.com/prior/repo"
        prior_state = StateStore::State.new(
          repos: {prior_key => StateStore::Repo.new(status: "clean")},
          orgs: {}
        )
        FileUtils.mkdir_p(File.dirname(state_file))
        StateStore.write(state_file, prior_state)
        prior_bytes = File.binread(state_file)

        # Simulate an in-flight run: acquire lock via an independent fd.
        FileUtils.mkdir_p(File.dirname(lock_path))
        in_flight = File.open(lock_path, File::RDWR | File::CREAT)
        assert in_flight.flock(File::LOCK_EX | File::LOCK_NB),
          "precondition: in-flight fd must acquire the lock"

        begin
          config = make_config(base_dir: base_dir, repos: [])
          scm = StubSCM.new(status_value: clean_status)
          # A contended lock emits a real `Kernel#warn` — capture_io keeps
          # that off the suite's combined stdout/stderr.
          result = nil
          capture_io { result = Engine.new(scm: scm).call(config: config, paths: paths) }

          # (a) state.yaml bytes unchanged — the in-flight run was not clobbered
          assert_equal prior_bytes, File.binread(state_file),
            "GA2(a): state.yaml must be byte-unchanged when another run holds the lock"

          # (b) returned without raising
          assert result.success?,
            "GA2(b): Engine#call must return Success (not raise) when lock is contended"

          # (c) distinguishable "skipped" signal: bytes unchanged is the observable proof;
          # result is Success (not a Failure/raise).
        ensure
          in_flight.flock(File::LOCK_UN)
          in_flight.close
        end

        # After releasing the lock the engine proceeds on a second call,
        # writes new state, and preserves prior rows (CF3 preservation intact).
        ref = RepoRef.new(host: "github.com", owner: "new", name: "repo")
        FileUtils.mkdir_p(File.join(base_dir, ref.host, ref.owner, ref.name))
        config2 = make_config(base_dir: base_dir, repos: [ref])
        scm2 = StubSCM.new(status_value: clean_status)
        result2 = Engine.new(scm: scm2).call(config: config2, paths: paths)
        assert result2.success?,
          "GA2: engine must proceed and write state after lock is released"

        final = StateStore.load(state_file).success
        assert final.repos[prior_key],
          "GA2: prior row must survive in final state (CF3 preservation intact)"
        assert final.repos["github.com/new/repo"],
          "GA2: new run's row must be present in final state"
      end
    end
  end

  # ===========================================================================
  # GA3 — Lock released on every exit path
  # After each scenario below, an independent flock(LOCK_EX | LOCK_NB) on
  # the sidecar SUCCEEDS, proving the engine released its lock via ensure.
  # (a) normal success, (b) write Failure, (c) escaping raise.
  # ===========================================================================
  def test_ga3a_lock_released_after_normal_success
    Dir.mktmpdir("rt-ga3a-") do |base_dir|
      with_paths(base_dir: base_dir) do |_, paths|
        ref = RepoRef.new(host: "github.com", owner: "owner", name: "rep")
        FileUtils.mkdir_p(File.join(base_dir, ref.host, ref.owner, ref.name))
        config = make_config(base_dir: base_dir, repos: [ref])
        scm = StubSCM.new(status_value: clean_status)
        result = Engine.new(scm: scm).call(config: config, paths: paths)
        assert result.success?

        lock_path = RepoTender::State::Lock.path_for(paths.state_file)
        fd = File.open(lock_path, File::RDWR | File::CREAT)
        assert fd.flock(File::LOCK_EX | File::LOCK_NB),
          "GA3(a): lock must be released after a successful run"
        fd.flock(File::LOCK_UN)
        fd.close
      end
    end
  end

  def test_ga3b_lock_released_after_write_failure
    # Drive a write Failure by seeding state.yaml with an invalid status
    # directly (bypassing Store.write validation). build_new_state preserves
    # the bogus row via prev.repos.dup; Store.write then fails validation.
    Dir.mktmpdir("rt-ga3b-") do |base_dir|
      with_paths(base_dir: base_dir) do |_, paths|
        state_file = paths.state_file
        FileUtils.mkdir_p(File.dirname(state_file))
        require "yaml"
        File.write(state_file, YAML.dump({
          "repos" => {"github.com/bad/repo" => {"status" => "bogus_status"}},
          "orgs" => {}
        }))

        # Empty repos config: bogus prior row survives build_new_state → write fails.
        config = make_config(base_dir: base_dir, repos: [])
        scm = StubSCM.new(status_value: clean_status)
        result = Engine.new(scm: scm).call(config: config, paths: paths)
        assert result.failure?,
          "GA3(b): engine must return Failure when Store.write validation fails"

        lock_path = RepoTender::State::Lock.path_for(state_file)
        fd = File.open(lock_path, File::RDWR | File::CREAT)
        assert fd.flock(File::LOCK_EX | File::LOCK_NB),
          "GA3(b): lock must be released even when write returns Failure"
        fd.flock(File::LOCK_UN)
        fd.close
      end
    end
  end

  def test_ga3c_lock_released_after_escaping_raise
    # Reuse the RaisingOnListingStartedReporter from G9.2: listing_started
    # raises before any rescue can catch it, propagating out of Engine#call.
    Dir.mktmpdir("rt-ga3c-") do |base_dir|
      with_paths(base_dir: base_dir) do |_, paths|
        reporter = RaisingOnListingStartedReporter.new
        config = make_config(base_dir: base_dir, repos: [])

        assert_raises(RuntimeError) do
          Engine.new(reporter: reporter).call(config: config, paths: paths)
        end

        lock_path = RepoTender::State::Lock.path_for(paths.state_file)
        fd = File.open(lock_path, File::RDWR | File::CREAT)
        assert fd.flock(File::LOCK_EX | File::LOCK_NB),
          "GA3(c): lock must be released even when an exception escapes Engine#call"
        fd.flock(File::LOCK_UN)
        fd.close
      end
    end
  end

  # ===========================================================================
  # GB2 — Empty remote → status: clean, last_error: nil (real git)
  # ===========================================================================
  def test_gb2_empty_repo_engine_yields_clean_not_error
    with_engine_home do |paths, base_dir, state_file|
      with_empty_repo do |_bare, clone|
        ref = RepoRef.new(host: "github.com", owner: "empty", name: "proj")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?, "engine failed on empty repo: #{result.failure.inspect}"

        state = StateStore.load(state_file).success
        row = state.repos["github.com/empty/proj"]
        refute_nil row, "empty repo must have a state row"
        assert_equal "clean", row.status,
          "empty repo must report status: clean (not error)"
        assert_nil row.last_error, "empty repo must not have last_error"
      end
    end
  end

  # ===========================================================================
  # GB3 — Empty clone + remote gains commits → fast-forwarded to clean (real git)
  # ===========================================================================
  def test_gb3_empty_clone_fast_forwards_when_remote_gains_commits
    with_engine_home do |paths, base_dir, state_file|
      with_empty_repo do |bare, clone|
        ref = RepoRef.new(host: "github.com", owner: "empty", name: "proj")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        # First run: empty remote → status: clean
        config = make_config(base_dir: base_dir, repos: [ref])
        result1 = Engine.new.call(config: config, paths: paths)
        assert result1.success?, "first engine run failed: #{result1.failure.inspect}"
        row1 = StateStore.load(state_file).success.repos["github.com/empty/proj"]
        assert_equal "clean", row1.status
        assert_nil row1.default_branch, "default_branch should be nil for still-empty remote"

        # Remote gains its first commit.
        push_first_commit_to_bare(bare, content: "hello\n", filename: "README.md")

        # Second run: should fetch + fast-forward.
        result2 = Engine.new.call(config: config, paths: paths)
        assert result2.success?, "second engine run failed: #{result2.failure.inspect}"

        state2 = StateStore.load(state_file).success
        row2 = state2.repos["github.com/empty/proj"]
        refute_nil row2
        assert_equal "clean", row2.status,
          "after gaining commits, status must be clean"
        assert_equal "trunk", row2.default_branch,
          "default_branch must be resolved after fast-forward"

        # File is on disk.
        assert File.exist?(File.join(repo_path, "README.md")),
          "README.md must be present after fast-forward into unborn branch"
        assert_equal "hello\n", File.read(File.join(repo_path, "README.md"))

        # git log resolves.
        log = Shell.run("git", "log", "--oneline", chdir: repo_path)
        assert log.success?, "git log must succeed after fast-forward"
        assert_includes log.success, "first commit"
      end
    end
  end

  # ===========================================================================
  # GB4 — Unborn+dirty → never mutated, files intact, status: dirty (real git)
  # ===========================================================================
  def test_gb4_unborn_dirty_never_mutated_files_intact
    with_engine_home do |paths, base_dir, state_file|
      with_empty_repo do |_bare, clone|
        ref = RepoRef.new(host: "github.com", owner: "empty", name: "proj")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        # Drop an untracked file — the GB4 cardinal test.
        sentinel_path = File.join(repo_path, "do_not_delete.txt")
        sentinel_content = "precious local work #{Process.pid}\n"
        File.write(sentinel_path, sentinel_content)

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"

        state = StateStore.load(state_file).success
        row = state.repos["github.com/empty/proj"]
        refute_nil row
        assert_equal "dirty", row.status,
          "GB4: unborn dirty repo must report status: dirty"
        assert_nil row.last_error,
          "GB4: dirty is an observation, not an error — last_error must be nil"

        # The file is byte-for-byte intact — no mutation occurred.
        assert File.exist?(sentinel_path),
          "GB4: untracked file must survive — no mutation on unborn dirty repo"
        assert_equal sentinel_content, File.read(sentinel_path),
          "GB4: file contents must be unchanged — byte-for-byte integrity"

        # HEAD is still unborn.
        in_async do
          status_out = Shell.run("git", "status", "--porcelain=v2", "--branch", chdir: repo_path)
          assert status_out.success?
          assert_includes status_out.success, "branch.oid (initial)",
            "GB4: HEAD must still be unborn after run on dirty unborn repo"
        end
      end
    end
  end

  # ===========================================================================
  # GB5 — Real errors stay errors (non-empty repo with real probe failure)
  # ===========================================================================
  def test_gb5_real_error_stays_error_not_swallowed_by_empty_path
    with_engine_home do |paths, base_dir, state_file|
      with_seeded_trunk_repo do |_bare, clone|
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        # Point origin at a non-existent remote to force a fetch error.
        in_async do
          Shell.run("git", "remote", "set-url", "origin",
            "/tmp/does-not-exist-#{Process.pid}.git", chdir: repo_path)
        end

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?, "engine must not abort even on a fetch error"

        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        refute_nil row
        assert_equal "error", row.status,
          "GB5: a real fetch failure on a non-empty repo must remain status: error"
        refute_nil row.last_error,
          "GB5: last_error must be set on a real fetch failure"
      end
    end
  end

  # ===========================================================================
  # G5 — engine plumbs realized action + commits to repo_finished
  # ===========================================================================

  def test_g5_fast_forwarded_repo_reported_with_action_and_commits
    reporter = RecordingReporter.new
    ref = RepoRef.new(host: "github.com", owner: "owner", name: "ff-repo")
    behind_status = clean_status(branch: "trunk", ahead: 0, behind: 1)

    Dir.mktmpdir("rt-g5-ff-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "github.com", "owner", "ff-repo"))
      with_paths(base_dir: dir) do |_, paths|
        scm = StubSCM.new(
          status_value: behind_status,
          default_branch_value: "trunk",
          fast_forward_value: 3
        )
        result = Engine.new(scm: scm, reporter: reporter).call(
          config: make_config(base_dir: dir, repos: [ref]), paths: paths
        )
        assert result.success?, "engine failed: #{result.failure.inspect}"

        key = "github.com/owner/ff-repo"
        ev = reporter.events.find { |e| e.first == :repo_finished && e[1] == key }
        refute_nil ev, "expected repo_finished event for #{key}"
        assert_equal :fast_forwarded, ev[3], "expected action :fast_forwarded, got #{ev[3].inspect}"
        assert_equal 3, ev[4], "expected commits 3, got #{ev[4].inspect}"
      end
    end
  end

  def test_g5_cloned_repo_reported_with_action_cloned
    reporter = RecordingReporter.new
    ref = RepoRef.new(host: "github.com", owner: "owner", name: "new-repo")

    Dir.mktmpdir("rt-g5-clone-") do |dir|
      # path does NOT exist → RepoPlan returns :clone
      with_paths(base_dir: dir) do |_, paths|
        scm = StubSCM.new(status_value: clean_status)
        result = Engine.new(scm: scm, reporter: reporter).call(
          config: make_config(base_dir: dir, repos: [ref]), paths: paths
        )
        assert result.success?, "engine failed: #{result.failure.inspect}"

        key = "github.com/owner/new-repo"
        ev = reporter.events.find { |e| e.first == :repo_finished && e[1] == key }
        refute_nil ev, "expected repo_finished event for #{key}"
        assert_equal :cloned, ev[3], "expected action :cloned, got #{ev[3].inspect}"
        assert_equal 0, ev[4], "expected commits 0, got #{ev[4].inspect}"
      end
    end
  end

  def test_g5_up_to_date_repo_reported_with_action_up_to_date
    reporter = RecordingReporter.new
    ref = RepoRef.new(host: "github.com", owner: "owner", name: "current-repo")
    up_to_date_status = clean_status(branch: "trunk", ahead: 0, behind: 0)

    Dir.mktmpdir("rt-g5-utd-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "github.com", "owner", "current-repo"))
      with_paths(base_dir: dir) do |_, paths|
        # fast_forward_value: 0 → up_to_date action
        scm = StubSCM.new(
          status_value: up_to_date_status,
          default_branch_value: "trunk",
          fast_forward_value: 0
        )
        result = Engine.new(scm: scm, reporter: reporter).call(
          config: make_config(base_dir: dir, repos: [ref]), paths: paths
        )
        assert result.success?, "engine failed: #{result.failure.inspect}"

        key = "github.com/owner/current-repo"
        ev = reporter.events.find { |e| e.first == :repo_finished && e[1] == key }
        refute_nil ev, "expected repo_finished event for #{key}"
        assert_equal :up_to_date, ev[3], "expected action :up_to_date, got #{ev[3].inspect}"
        assert_equal 0, ev[4], "expected commits 0, got #{ev[4].inspect}"
      end
    end
  end
end
