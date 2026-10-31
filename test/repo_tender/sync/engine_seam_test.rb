# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "time"

# The store seam end-to-end: a FakeBackend collaborator (in-memory
# State, records every save, lock always acquires) driving the REAL
# engine with `state_backend:` injected and `paths: nil`. The fakes
# sit at the seam boundary — the engine, plan, and state value
# objects under test are all real.
class SyncEngineSeamTest < Minitest::Test
  include TestHelpers

  Engine = RepoTender::Sync::Engine
  Config = RepoTender::Config::Config
  RepoRef = RepoTender::Config::RepoRef
  OrgRef = RepoTender::Config::OrgRef
  StateStore = RepoTender::State::Store
  Status = RepoTender::SCM::Status

  # In-memory State::Backend: hands the engine its seeded state,
  # records every state the engine saves, never touches disk.
  class FakeBackend < RepoTender::State::Backend
    attr_reader :saved

    def initialize(state: StateStore::State.new)
      @state = state
      @saved = []
    end

    def load
      Dry::Monads::Success(@state)
    end

    def save(state)
      @state = state
      @saved << state
      Dry::Monads::Success(state)
    end

    def with_exclusive_lock
      yield
    end
  end

  # Minimal pure-Ruby SCM double (engine_test.rb's StubSCM, trimmed
  # to the clean-status path this file exercises).
  class StubSCM
    def initialize(status:)
      @status = status
    end

    def status(_path) = Dry::Monads::Success(@status)
    def current_branch(_path) = Dry::Monads::Success("trunk")
    def default_branch(_path) = Dry::Monads::Success("trunk")
    def last_fetch_at(_path) = Dry::Monads::Success(nil)
    def fetch(_path) = Dry::Monads::Success(:ok)
    def switch(_path, branch) = Dry::Monads::Success(branch)
    def clone(_url, path) = Dry::Monads::Success(path)
    def fast_forward(_path, _branch) = Dry::Monads::Success(0)
    def sync_empty(_path) = Dry::Monads::Success(:empty)
  end

  # Forge double: auth ok; list_org outcome from a callable.
  class StubForge
    def initialize(list_org:)
      @list_org = list_org
    end

    def check_authenticated = Dry::Monads::Success(:authenticated)

    def list_org(org_ref)
      outcome = @list_org.call(org_ref)
      outcome.is_a?(Dry::Monads::Result) ? outcome : Dry::Monads::Success(outcome)
    end
  end

  def clean_status
    Status.new(clean: true, branch: "trunk", upstream: "origin/trunk", ahead: 0, behind: 0)
  end

  def make_config(base_dir:, repos: [], orgs: [])
    Config.new(base_dir: base_dir, refresh_interval: 3600, concurrency: 2,
      repos: repos, orgs: orgs)
  end

  def test_call_without_paths_or_state_backend_raises_argument_error
    Dir.mktmpdir("rt-seam-arg-") do |base_dir|
      config = make_config(base_dir: base_dir)
      error = assert_raises(ArgumentError) do
        Engine.new.call(config: config)
      end
      assert_match(/paths.*state_backend/, error.message)
    end
  end

  def test_merged_run_state_arrives_via_save_and_no_file_is_written
    Dir.mktmpdir("rt-seam-save-") do |base_dir|
      with_paths(base_dir: base_dir) do |_env, paths|
        ref = RepoRef.new(host: "github.com", owner: "owner", name: "rep")
        FileUtils.mkdir_p(File.join(base_dir, "github.com", "owner", "rep"))

        backend = FakeBackend.new
        engine = Engine.new(
          scm: StubSCM.new(status: clean_status),
          forge: StubForge.new(list_org: ->(_o) { [] }),
          state_backend: backend
        )
        result = engine.call(config: make_config(base_dir: base_dir, repos: [ref]), paths: nil)
        assert result.success?, result.failure.inspect
        assert_equal 1, result.success.processed

        # The merged state crossed the seam through save — exactly one
        # save per run, carrying the processed repo's row.
        assert_equal 1, backend.saved.size,
          "one run saves exactly once through the backend"
        saved = backend.saved.first
        assert_kind_of StateStore::State, saved
        row = saved.repos["github.com/owner/rep"]
        refute_nil row, "processed repo row must be in the saved state"
        assert_equal "clean", row.status

        # And the report's state is the same merged state.
        assert_equal saved, result.success.state

        # No paths: means no default file backend — nothing on disk.
        refute File.exist?(paths.state_file),
          "an injected backend must not write a state file anywhere"
        state_contents = File.exist?(paths.state_dir) ? Dir.children(paths.state_dir) : []
        assert_empty state_contents, "the run left nothing in the XDG state dir"
      end
    end
  end

  def test_injected_backend_wins_over_paths
    Dir.mktmpdir("rt-seam-wins-") do |base_dir|
      with_paths(base_dir: base_dir) do |_env, paths|
        ref = RepoRef.new(host: "github.com", owner: "owner", name: "rep")
        FileUtils.mkdir_p(File.join(base_dir, "github.com", "owner", "rep"))

        backend = FakeBackend.new
        engine = Engine.new(
          scm: StubSCM.new(status: clean_status),
          forge: StubForge.new(list_org: ->(_o) { [] }),
          state_backend: backend
        )
        # paths IS passed here — the injected backend must still win:
        # the run goes to the fake, not to paths.state_file.
        result = engine.call(config: make_config(base_dir: base_dir, repos: [ref]), paths: paths)
        assert result.success?
        assert_equal 1, backend.saved.size
        refute File.exist?(paths.state_file),
          "injected backend wins over paths:; no YAML state file may appear"
      end
    end
  end

  def test_prior_org_rows_preserved_through_the_seam_on_org_failure
    Dir.mktmpdir("rt-seam-orgfail-") do |base_dir|
      prior_listed_at = Time.utc(2026, 6, 13, 10, 0, 0)
      seeded = StateStore::State.new(
        repos: {},
        orgs: {
          "github.com/socketry" => StateStore::Org.new(
            last_listed_at: prior_listed_at,
            repo_count: 2
          )
        }
      )
      backend = FakeBackend.new(state: seeded)
      org = OrgRef.new(host: "github.com", name: "socketry")
      engine = Engine.new(
        scm: StubSCM.new(status: clean_status),
        forge: StubForge.new(
          list_org: ->(o) { Dry::Monads::Failure({org: o.name, reason: "rate limit"}) }
        ),
        clock: -> { Time.utc(2026, 6, 13, 11, 0, 0) },
        state_backend: backend
      )

      result = engine.call(config: make_config(base_dir: base_dir, orgs: [org]), paths: nil)
      assert result.success?, "an org-list failure must not abort the run: #{result.failure.inspect}"

      # CF3 through the seam: the prior good repo_count + last_listed_at
      # survive the failure, last_error records it.
      saved = backend.saved.first
      refute_nil saved, "the run must still save its merged state"
      org_row = saved.orgs["github.com/socketry"]
      refute_nil org_row
      assert_equal 2, org_row.repo_count, "prior repo_count preserved across the seam"
      assert_equal prior_listed_at, org_row.last_listed_at, "prior last_listed_at preserved across the seam"
      assert_includes org_row.last_error, "rate limit"
    end
  end

  def test_organ_listing_state_flows_through_the_seam_on_success
    Dir.mktmpdir("rt-seam-orgok-") do |base_dir|
      discovered = [
        RepoRef.new(host: "github.com", owner: "socketry", name: "lib0"),
        RepoRef.new(host: "github.com", owner: "socketry", name: "lib1")
      ]
      2.times { |i| FileUtils.mkdir_p(File.join(base_dir, "github.com", "socketry", "lib#{i}")) }

      listed_at = Time.utc(2026, 10, 30, 12, 0, 0)
      backend = FakeBackend.new
      org = OrgRef.new(host: "github.com", name: "socketry")
      engine = Engine.new(
        scm: StubSCM.new(status: clean_status),
        forge: StubForge.new(list_org: ->(_o) { discovered }),
        clock: -> { listed_at },
        state_backend: backend
      )

      result = engine.call(config: make_config(base_dir: base_dir, orgs: [org]), paths: nil)
      assert result.success?

      saved = backend.saved.first
      org_row = saved.orgs["github.com/socketry"]
      assert_equal 2, org_row.repo_count
      assert_equal listed_at, org_row.last_listed_at
      assert saved.repos["github.com/socketry/lib0"], "discovered repos processed through the seam"
      assert saved.repos["github.com/socketry/lib1"]
    end
  end
end
