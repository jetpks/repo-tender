# frozen_string_literal: true

require "dry/monads"
require "repo_tender/cli/repo"  # for Repo::Helpers.parse_ref
require "repo_tender/cli/options"
require "repo_tender/ui/mode"
require "repo_tender/ui/plain_reporter"
require "repo_tender/ui/json_reporter"
require "repo_tender/ui/interactive_reporter"

module RepoTender
  module CLI
    # `sync` command: invoke Sync::Engine over the full config, or
    # scope to a single repo with --repo.
    #
    # Scoping is implemented at the CLI layer (per gate G4): the
    # CLI builds a filtered Config (Config::Store.with(config,
    # repos: [match], orgs: [])) and passes it to the unchanged
    # engine. Sync::Engine#call is (config:, paths:) — there is no
    # scoping parameter on the engine, and the spec forbids editing
    # sync/engine.rb in this slice.
    module Sync
      class Run < Dry::CLI::Command
        include GlobalOptions

        desc "Run one sync pass (use --repo to scope to a single tracked repo)"
        option :repo, desc: "Scope to a single tracked repo (host/owner/name)"

        def call(repo: nil, plain: nil, json: nil, no_color: nil, quiet: nil, **)
          paths = CLI.make_paths
          paths.ensure!
          config = Config::Store.load(paths.config_file).success

          # Log rotation pre-step (slice-4 gate G5). launchd owns
          # the stdout/stderr redirect via StandardOutPath /
          # StandardErrorPath; the sync process rotates those
          # files at the start of each run so the previous run's
          # log doesn't grow unbounded. The rotator renames the
          # file to a timestamped archive (preserving bytes); the
          # current process's inherited fd still points to the
          # renamed file, so writes during this run succeed.
          # launchd opens a fresh file at the original path on
          # the next spawn. No-op when the log is missing or
          # under-threshold (sync tests in G4 stay green).
          rotate_plist_logs(paths)

          # Resolved BEFORE the scoping block: the "scoping sync to:"
          # notice below is prose, and must be suppressed in JSON mode
          # for the same reason the summary line is. Resolution depends
          # only on flags/env/out, so it is safe this early.
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          # Every line of --json output must parse as one JSON object.
          human = mode.format != :json

          if repo
            target = scope_target(repo)
            return fail_with(self, "invalid repo reference: #{repo.inspect} (expected host/owner/name)") if target.failure?

            match = target.success
            found = config.repos.find { |r| Repo::Helpers.same_repo?(r, match) }
            if found.nil?
              return fail_with(self, "no such tracked repo: #{Repo::Helpers.format_ref(match)}")
            end
            # Filtered config: only the one matched repo, no orgs
            # (org expansion would discover other repos — that's
            # exactly the G4 "other repo gets no state row" test
            # path, so we explicitly empty orgs here).
            config = Config::Store.with(config, repos: [found], orgs: [])
            out.puts "scoping sync to: #{Repo::Helpers.format_ref(found)}" if human
          end

          reporter = if mode.format == :json
            UI::JsonReporter.new(out)
          elsif mode.animate
            UI::InteractiveReporter.new(out, mode: mode)
          else
            UI::PlainReporter.new(out, mode: mode)
          end

          # prune only on a full sweep. With --repo the config above was
          # narrowed to one repo, so pruning would delete the state rows
          # for every OTHER tracked repo.
          result = RepoTender::Sync::Engine.new(reporter: reporter)
            .call(config: config, paths: paths, prune: repo.nil?)
          if result.failure?
            return fail_with(self, "sync failed: #{format_failure(result.failure)}")
          end

          report = result.success
          # JsonReporter already emits a run_finished event carrying the
          # summary, so suppressing the prose line loses nothing.
          out.puts "synced #{report.processed} repo(s)" if human
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end

        private

        def scope_target(repo)
          Repo::Helpers.parse_ref(repo)
        end

        def format_failure(f) = f.is_a?(Hash) ? f.inspect : f.to_s

        def fail_with(cmd, msg)
          cmd.send(:err).puts msg
          RepoTender::CLI.record_outcome(Outcome.new(exit_code: 1, message: msg))
        end

        # Default log-rotation threshold: 10 MiB. Tunable via the
        # env var `REPO_TENDER_LOG_MAX_BYTES` (introspection /
        # ops escape hatch). The LogRotator itself is unit-tested
        # with an injected threshold (gate G5).
        DEFAULT_LOG_MAX_BYTES = 10 * 1024 * 1024

        def rotate_plist_logs(paths)
          threshold = log_max_bytes
          label = Launchd::Agent::DEFAULT_LABEL
          [File.join(paths.log_dir, "#{label}.out.log"),
            File.join(paths.log_dir, "#{label}.err.log")].each do |p|
            RepoTender::LogRotator.call(p, threshold_bytes: threshold)
          end
        end

        # CF6 (Slice 5): defensively parse the
        # `REPO_TENDER_LOG_MAX_BYTES` env var so a malformed
        # operator value (e.g. `"10MB"`) falls back to the
        # 10 MiB default instead of raising `ArgumentError`
        # and crashing the entire `sync` run before any repo
        # work.
        #
        # Accepted: any positive integer in base 10
        # (e.g. `"1048576"`, `"  524288  "`). Falls back to
        # `DEFAULT_LOG_MAX_BYTES` (and emits a single
        # `Kernel#warn` to stderr) for: unset, empty,
        # whitespace, non-numeric (`"10MB"`, `"abc"`), zero,
        # and negative inputs. Never raises.
        #
        # The optional `env_value` arg exists so the unit
        # tests can pass arbitrary values without mutating
        # the real `ENV`; production callers invoke with
        # no args and the method reads `ENV` itself.
        def log_max_bytes(env_value = ENV["REPO_TENDER_LOG_MAX_BYTES"])
          return DEFAULT_LOG_MAX_BYTES if env_value.nil? || env_value.strip.empty?

          parsed = Integer(env_value, 10, exception: false)
          return parsed if parsed.is_a?(Integer) && parsed.positive?

          warn "repo-tender: REPO_TENDER_LOG_MAX_BYTES=#{env_value.inspect} is invalid; " \
            "falling back to #{DEFAULT_LOG_MAX_BYTES} bytes"
          DEFAULT_LOG_MAX_BYTES
        end
      end
    end
  end
end

RepoTender::CLI::Registry.register "sync", RepoTender::CLI::Sync::Run
