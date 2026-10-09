# frozen_string_literal: true

require "fileutils"
require "time"
require "async"
require "async/barrier"
require "async/semaphore"
require "dry/monads"
require "repo_tender/config/model"
require "repo_tender/scm/git"
require "repo_tender/forge/github"
require "repo_tender/state/store"
require "repo_tender/state/lock"
require "repo_tender/paths"
require "repo_tender/sync/repo_plan"
require "repo_tender/sync/report"
require "repo_tender/ui/reporter"

module RepoTender
  module Sync
    # The sync engine: one run that brings every tracked repo to the
    # evergreen invariant (PRD §3.3). Splits observation (RepoPlan)
    # from execution (this class). Bounded by Async::Semaphore
    # (config.concurrency) inside one Sync{} block. A single repo's
    # Failure does NOT abort the run — it is captured, the state row
    # is written as status: error, and the run continues.
    #
    # Slice 2 gate wiring:
    #   G7  — Async::Semaphore(concurrency) bounds the in-flight count.
    #   G8  — every processed repo gets a state row; failures are
    #         recorded with status: error + last_error.
    #   G9  — second run on a fresh set performs no network calls
    #         (the :skip_fresh plan short-circuits the SCM.fetch).
    #   G10 — OrgRef expansion via the injected forge; an org-list
    #         Failure is recorded and does not abort the run.
    #
    # sync-startup gate wiring (GS1–GS6):
    #   GS1 — expand_orgs fans org listings out concurrently via
    #         Async::Barrier + Async::Semaphore(config.concurrency).
    #   GS2 — forge.check_authenticated called ONCE before fan-out;
    #         on auth Failure all orgs recorded failed, no list_org.
    #   GS3 — CF3 / G10 resilience preserved (per-org failure isolated,
    #         prior repo_count/last_listed_at preserved on failure).
    #   GS4 — reporter events: attach → listing_started → org_listed*
    #         → listing_finished → run_started → repo* → run_finished
    #         → detach.
    class Engine
      extend Dry::Monads[:result]

      # `Success` and `Failure` are used inside the `call` instance
      # method (via the `Sync{}` block). Per Slice 1 convention
      # (see SCM::Client / SCM::Git / Shell), we use the fully-
      # qualified `Dry::Monads::Success(...)` from inside instance
      # methods. The `extend` is kept so class-level callers (tests,
      # future helpers) can use the short form.

      # Default clone URL: scp-like SSH form `git@<host>:<owner>/<name>.git`.
      # SSH uses the user's configured SSH keys (default
      # `~/.ssh/id_rsa`/whatever `~/.ssh/config` resolves) with no
      # interactive `Username for 'https://github.com':` prompt — the
      # field defect Slice 6 fixed (the previous HTTPS default made
      # a missing-repo clone prompt for credentials). This is the
      # seam the Slice 2 disagreement-#6 ruling anticipated ("legit
      # future seam (ssh/token)"). No new config field is added in
      # this slice — the transport flip is on the default builder
      # only; tests can still inject a different builder (e.g.
      # file:// for a local bare remote in the G6 missing-path test).
      DEFAULT_URL_BUILDER = ->(ref) { "git@#{ref.host}:#{ref.owner}/#{ref.name}.git" }.freeze

      def initialize(scm: SCM::Git.new, forge: Forge::GitHub.new,
        clock: -> { Time.now }, url_builder: DEFAULT_URL_BUILDER,
        reporter: RepoTender::UI::NullReporter.new)
        @scm = scm
        @forge = forge
        @clock = clock
        @url_builder = url_builder
        @reporter = reporter
      end

      # Runs one sync pass.
      # @param config [Config::Config] the validated config struct
      # @param paths  [Paths]         the XDG paths object
      # @param prune  [Boolean] drop state rows for repos this run did
      #   not see. Only the CALLER can know whether `config` is the
      #   complete tracked set or a scoped subset — the engine cannot
      #   tell "user tracks one repo" from "user passed --repo" — so
      #   this is never inferred here. Defaults to false: never delete
      #   unless explicitly told to. Even when true, pruning is skipped
      #   if any org listing failed (see below).
      # @return [Dry::Monads::Result<Report>] the merged state plus the
      #   count of repos this run processed. The two are distinct: state
      #   accumulates every repo ever synced, `processed` is this run's
      #   work (see Sync::Report).
      def call(config:, paths:, prune: false)
        Sync do |task|
          semaphore = Async::Semaphore.new(config.concurrency, parent: task)
          barrier = Async::Barrier.new

          # Acquire an exclusive advisory lock on the sidecar lockfile
          # BEFORE loading state. Held across the entire load→write span
          # so an overlapping run never writes and cannot clobber the
          # in-flight run's data (CF10). Non-blocking: if another run
          # holds the lock we bail cleanly rather than blocking forever
          # (a blocked launchd tick would pile up on every subsequent
          # StartInterval fire).
          lock_result = State::Lock.acquire(paths.state_file) do
            # State is loaded once at the start (or initialized empty for
            # a missing state.yaml). A new State object is built from
            # the run's outcomes and written atomically at the end. Per-
            # repo state rows that did not change are preserved.
            state = State::Store.load(paths.state_file).success
            now = @clock.call

            # Attach the reporter before expansion so the render fiber is
            # alive during listing (GS4: attach fires before listing_started).
            @reporter.attach(task)
            begin
              # Phase 1: org expansion (concurrent; per-org failures isolated).
              # CF3 (Slice 4 Lane 02) passes the prev state's org map so an
              # org-list Failure can preserve the prior good repo_count +
              # last_listed_at instead of clobbering with 0/nil.
              org_records, discovered_repos = expand_orgs(config, now, prev_orgs: state.orgs, task: task, semaphore: semaphore)

              # Phase 2: dedupe explicit + discovered repos by (host, owner,
              # name); explicit wins.
              repos_to_process = dedupe(config.repos, discovered_repos)

              @reporter.run_started(total: repos_to_process.size)

              # Phase 3: fan out per-repo work through barrier + semaphore.
              # Results are gathered in a mutex-protected array (barrier
              # tasks run on a Fiber scheduler; shared mutation must be
              # serialized). Each result is a [key, Repo | nil, error] tuple
              # (see process_one for the shape).
              results_mutex = Mutex.new
              results = []

              repos_to_process.each do |repo_ref|
                barrier.async do
                  # `semaphore.async` spawns a child task and returns its
                  # Task handle. The barrier only tracks this outer task;
                  # if we don't `.wait` on the inner task, `barrier.wait`
                  # would return before the per-repo work finishes and
                  # `build_new_state` would see an empty results array.
                  inner = semaphore.async do
                    outcome = process_one(repo_ref, config, now)
                    results_mutex.synchronize { results << outcome }
                  end
                  inner.wait
                end
              end
              barrier.wait

              summary = results.each_with_object(Hash.new(0)) do |outcome, h|
                _, repo, error = outcome
                h[error ? "error" : repo.status.to_s] += 1
              end
              @reporter.run_finished(summary)

              # Phase 4: assemble new state, write once.
              #
              # A failed org listing means `discovered` is missing that
              # org's repos through no fault of the user's config, so
              # pruning would delete every row for a whole org on a
              # transient forge outage. Only prune when the run saw the
              # complete picture.
              listings_complete = org_records.each_value.none?(&:last_error)
              new_state = build_new_state(
                state, results, org_records, prune: prune && listings_complete
              )
              write_result = State::Store.write(paths.state_file, new_state)
              if write_result.failure?
                write_result
              else
                # results.size, not new_state.repos.size — the latter is
                # the accumulated state file and would report every repo
                # ever synced (553 on a scoped one-repo run).
                Dry::Monads::Success(Report.new(state: new_state, processed: results.size))
              end
            ensure
              @reporter.detach
            end
          end

          if lock_result == State::Lock::NOT_ACQUIRED
            warn "repo-tender: skipped — another sync in progress"
            # Nothing ran, so processed is 0 — the state is returned only
            # so callers still get a usable snapshot.
            Dry::Monads::Success(
              Report.new(state: State::Store.load(paths.state_file).success, processed: 0)
            )
          else
            lock_result
          end
        end
      end

      private

      # Expands each OrgRef into RepoRefs via the injected forge.
      # Authenticates ONCE before the fan-out (GS2). On auth Failure,
      # records all orgs failed without calling list_org (CF3 preserved).
      # On per-org list_org Failure, the org is recorded with the prior
      # good repo_count + last_listed_at preserved (CF3), last_error set.
      # Fan-out is concurrent via Async::Barrier + Async::Semaphore
      # (GS1: wall-time bounded by slowest org, not sum-of-orgs).
      def expand_orgs(config, now, prev_orgs:, task:, semaphore:)
        org_records = {}
        discovered = []
        org_mutex = Mutex.new

        @reporter.listing_started(total: config.orgs.size)

        if config.orgs.empty?
          @reporter.listing_finished
          return [org_records, discovered]
        end

        auth = @forge.check_authenticated
        if auth.failure?
          # Auth failed once — record all orgs as failed without listing.
          config.orgs.each do |org_ref|
            key = org_key(org_ref)
            prev = prev_orgs[key]
            org_records[key] = State::Store::Org.new(
              last_listed_at: prev&.last_listed_at,
              repo_count: prev&.repo_count || 0,
              last_error: format_org_failure(auth.failure)
            )
            @reporter.org_listed(org_ref, count: nil)
          end
          @reporter.listing_finished
          return [org_records, discovered]
        end

        # Fan out: one fiber per org, bounded by the same semaphore used
        # for the repo sweep (GS1). A separate org_barrier keeps the
        # listing phase isolated from the repo sweep.
        org_barrier = Async::Barrier.new

        config.orgs.each do |org_ref|
          org_barrier.async do
            inner = semaphore.async do
              result = @forge.list_org(org_ref)
              key = org_key(org_ref)
              if result.success?
                repos = result.success
                row = State::Store::Org.new(
                  last_listed_at: now,
                  repo_count: repos.length
                )
                org_mutex.synchronize do
                  org_records[key] = row
                  discovered.concat(repos)
                end
                @reporter.org_listed(org_ref, count: repos.length)
              else
                prev = prev_orgs[key]
                row = State::Store::Org.new(
                  last_listed_at: prev&.last_listed_at,
                  repo_count: prev&.repo_count || 0,
                  last_error: format_org_failure(result.failure)
                )
                org_mutex.synchronize { org_records[key] = row }
                @reporter.org_listed(org_ref, count: nil)
              end
            rescue => e
              key = org_key(org_ref)
              prev = prev_orgs[key]
              row = State::Store::Org.new(
                last_listed_at: prev&.last_listed_at,
                repo_count: prev&.repo_count || 0,
                last_error: "unhandled: #{e.class}: #{e.message}"
              )
              org_mutex.synchronize { org_records[key] = row }
              @reporter.org_listed(org_ref, count: nil)
            end
            inner.wait
          end
        end
        org_barrier.wait

        @reporter.listing_finished
        [org_records, discovered]
      end

      def org_key(o) = "#{o.host}/#{o.name}"

      def format_org_failure(failure)
        return "list failed" if failure.nil?
        return failure[:reason] if failure.is_a?(Hash) && failure[:reason]
        failure.inspect
      end

      def repo_key(r) = "#{r.host}/#{r.owner}/#{r.name}"

      # First-write-wins dedupe keyed by (host, owner, name).
      def dedupe(explicit, discovered)
        seen = {}
        explicit.each { |r| seen[repo_key(r)] ||= r }
        discovered.each { |r| seen[repo_key(r)] ||= r }
        seen.values
      end

      # Process a single repo: plan + execute. Returns
      #   [key, Repo]                                  on success
      #   [key, nil, error_string]                     on action Failure
      #   [key, nil, "unhandled: ..."]                 on unexpected raise
      # The last-resort rescue is the engine's G8 guarantee: nothing
      # in process_one propagates an exception out of the semaphore.
      def process_one(repo_ref, config, now)
        key = repo_key(repo_ref)
        path = File.join(config.base_dir, repo_ref.host, repo_ref.owner, repo_ref.name)

        @reporter.repo_started(key)

        plan_result = RepoPlan.call(
          repo_ref: repo_ref,
          path: path,
          scm: @scm,
          refresh_interval: config.refresh_interval,
          now: now
        )
        if plan_result.failure?
          msg = "plan call failed: #{plan_result.failure.inspect}"
          @reporter.repo_failed(key, msg)
          return [key, nil, msg]
        end
        plan = plan_result.success

        # The plan's default_branch is implicit in the decision but
        # not exposed in the Plan object. The engine re-probes
        # default_branch for the state record. We MUST NOT call
        # scm.default_branch(path) before the clone — `chdir:` to a
        # non-existent path raises ENOENT in `Kernel#spawn`, which is
        # not a clean Failure (it's an exception, not a non-zero
        # exit). So default_branch is initialized to nil and only
        # populated after the path exists.
        default_branch = nil

        final_status = plan.status
        last_error = nil
        realized_action = nil
        realized_commits = 0

        case plan.action
        when :clone
          @reporter.repo_phase(key, :cloning)
          result = @scm.clone(@url_builder.call(repo_ref), path)
          if result.failure?
            final_status = "error"
            last_error = "clone failed: #{result.failure.inspect}"
            realized_action = :error
          else
            # The clone succeeded; the repo is now "clean" (a fresh
            # clone has no local changes). Re-probe default_branch on
            # the now-cloned path.
            final_status = "clean"
            default_branch = @scm.default_branch(path).value_or { nil }
            realized_action = :cloned
          end
        when :fast_forward
          default_branch = @scm.default_branch(path).value_or { nil }
          if default_branch.nil?
            final_status = "error"
            last_error = "default_branch probe failed; cannot fast-forward"
            realized_action = :error
          else
            @reporter.repo_phase(key, :fast_forwarding)
            result = @scm.fast_forward(path, default_branch)
            if result.failure?
              failure = result.failure
              if failure.is_a?(Hash) && failure[:reason].to_s.include?("diverged")
                # G4: divergence is not an error — it's a state.
                final_status = "diverged"
                last_error = failure[:reason].to_s
                realized_action = :diverged
              else
                final_status = "error"
                last_error = failure.inspect
                realized_action = :error
              end
            else
              realized_commits = result.success
              realized_action = (realized_commits > 0) ? :fast_forwarded : :up_to_date
            end
          end
        when :switch
          default_branch = @scm.default_branch(path).value_or { nil }
          if default_branch.nil?
            final_status = "error"
            last_error = "default_branch probe failed; cannot switch"
            realized_action = :error
          else
            # The plan only returns :switch for a clean tree (gate G5;
            # disagreement #1), so this scm.switch is on a clean tree.
            # git switch refuses on dirty by default per its man page;
            # if it ever refused here, that means the plan's guard was
            # bypassed — capture the error.
            @reporter.repo_phase(key, :switching)
            result = @scm.switch(path, default_branch)
            if result.failure?
              final_status = "error"
              last_error = result.failure.inspect
              realized_action = :error
            else
              # The switch succeeded; the repo is now on the default
              # branch with a clean tree.
              final_status = "clean"
              realized_action = :switched
            end
          end
        when :sync_empty
          result = @scm.sync_empty(path)
          if result.failure?
            final_status = "error"
            last_error = "empty-repo sync failed: #{result.failure.inspect}"
            realized_action = :error
          else
            final_status = "clean"
            # empty-repo commit counts are not tracked (commits: 0 always)
            realized_action = :up_to_date
            # nil-safe: still-empty remote → default_branch returns Failure
            default_branch = @scm.default_branch(path).value_or { nil }
          end
        when :skip_fresh, :up_to_date
          # No SCM side effect. State is already "clean". Probe
          # default_branch for the state record (cheap — cached on
          # first call).
          default_branch = @scm.default_branch(path).value_or { nil }
          realized_action = :up_to_date
        when :report_dirty
          default_branch = @scm.default_branch(path).value_or { nil }
          realized_action = :dirty
        when :report_diverged
          default_branch = @scm.default_branch(path).value_or { nil }
          realized_action = :diverged
        when :report_wrong_branch
          default_branch = @scm.default_branch(path).value_or { nil }
          realized_action = :wrong_branch
        when :report_detached
          default_branch = @scm.default_branch(path).value_or { nil }
          realized_action = :detached
        when :report_error
          # The plan classified a probe failure; the diagnostic goes
          # into last_error. Don't re-probe default_branch — the path
          # may not exist or the probe may still fail.
          last_error = plan.reason
          realized_action = :error
        end

        last_fetch = @scm.last_fetch_at(path).value_or { nil }
        repo = State::Store::Repo.new(
          default_branch: default_branch,
          last_fetch_at: last_fetch,
          last_synced_at: now,
          status: final_status,
          last_error: last_error
        )
        @reporter.repo_finished(key, final_status, action: realized_action, commits: realized_commits)
        [key, repo]
      rescue => e
        # Last-resort: any unexpected exception (e.g. Shell.run raising
        # outside an ambient task) is captured so the engine's barrier
        # completes and state is written.
        msg = "unhandled: #{e.class}: #{e.message}"
        @reporter.repo_failed(key, msg)
        [key, nil, msg]
      end

      # Assembles the new State from the in-memory prev state + the
      # run's per-repo outcomes + the org records. Failures get a
      # status: error row so every processed repo has a state entry
      # (gate G8).
      #
      # With prune: false (the default) rows for repos this run did not
      # process are carried over untouched — that is what keeps a scoped
      # `sync --repo` from deleting every other repo's state.
      #
      # With prune: true the carry-over is dropped, so the new state
      # holds exactly the repos this run processed and rows for repos
      # removed from config stop accumulating. Starting from an empty
      # hash is equivalent to selecting the processed keys out of prev:
      # every repo in the sweep contributes exactly one result tuple
      # (process_one's rescue guarantees one even on an unhandled
      # raise), so each gets a fresh row in the merge below.
      def build_new_state(prev, results, org_records, prune: false)
        repos = prune ? {} : prev.repos.dup
        results.each do |key, repo, error|
          repos[key] = (repo || State::Store::Repo.new(
            default_branch: nil,
            last_fetch_at: nil,
            last_synced_at: nil,
            status: "error",
            last_error: error
          ))
        end
        orgs = prev.orgs.merge(org_records)
        State::Store::State.new(repos: repos, orgs: orgs)
      end
    end
  end
end
