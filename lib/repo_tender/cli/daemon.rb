# frozen_string_literal: true

require "pastel"
require "fileutils"
require "dry/monads"
require "repo_tender/ui/mode"
require "repo_tender/cli/options"
require "repo_tender/launchd/agent"
require "repo_tender/launchd/plist"
require "repo_tender/migration"

module RepoTender
  module CLI
    # `daemon` command group: install / uninstall / start / stop
    # / restart / status. Installs a per-user launchd agent
    # (`gui/<UID>`) that fires `repo-tender sync` on a
    # `StartInterval`. The launchctl side is exercised ONLY
    # through an injected command runner (slice-4 gates G2–G4);
    # the live domain is proven by the manual real-Mac checklist
    # in docs/gates/slice-4.md, not by these tests.
    module Daemon
      module Helpers
        module_function

        # Build a `Launchd::Agent` wired against the CLI's env
        # seam (`CLI.env`). Tests inject a temp HOME (so
        # `paths.launch_agents_dir` is under the temp HOME, not
        # the real one) and a `runner:` via `Launchd::Agent.new`
        # — the daemon commands don't accept a runner flag, so
        # tests must use a real `Agent` (whose default `runner`
        # only fires in an ambient Async::Task) OR stub the
        # `Launchd::Agent` class.
        def make_agent(uid: Process.uid, label: Launchd::Agent::DEFAULT_LABEL, runner: nil)
          if runner
            Launchd::Agent.new(runner: runner, uid: uid, label: label)
          else
            Launchd::Agent.new(uid: uid, label: label)
          end
        end

        # Resolve the on-disk plist path for the agent label,
        # rooted at the env's HOME-resolved `LaunchAgents/`
        # (per slice-4 gate G3).
        def plist_path(paths, label)
          File.join(paths.launch_agents_dir, "#{label}.plist")
        end

        # Build the plist XML by looking up the absolute paths
        # the launchd runtime needs (mise, ruby, the bin
        # script, the repo root, the mise.toml). These come
        # from a few places:
        #   * `mise_bin` — `which mise` (we shell out at
        #      install-time; the result is baked into the plist
        #      as an absolute path so launchd's empty PATH
        #      doesn't matter).
        #   * `ruby_bin` — `mise exec -- which ruby` (the
        #      toolchain-resolved ruby; pinned via mise.toml).
        #   * `bin_path` — `RbConfig.ruby` + the script path
        #      (we use `__dir__` of this file's caller; for the
        #      gem install, this is `<gem>/exe/repo-tender`).
        #
        # In tests, we inject these via the `Resolve` object
        # (see below) — never call out to the shell.
        def build_plist(resolve:, config:, paths:, label:)
          Launchd::Plist.call(
            label: label,
            refresh_interval: config.refresh_interval,
            log_dir: paths.log_dir,
            repo_root: resolve.repo_root,
            mise_toml: resolve.mise_toml,
            mise_bin: resolve.mise_bin,
            ruby_bin: resolve.ruby_bin,
            bin_path: resolve.bin_path
          )
        end

        def format_failure(f) = f.is_a?(Hash) ? f.inspect : f.to_s

        def fail_with(cmd, msg)
          cmd.send(:err).puts msg
          RepoTender::CLI.record_outcome(Outcome.new(exit_code: 1, message: msg))
        end

        # Bundle of resolved absolute paths the plist needs.
        # Production code resolves these via the shell (see
        # `Resolve.detect`); tests construct one directly with
        # known absolute paths.
        Resolve = Data.define(:repo_root, :mise_toml, :mise_bin, :ruby_bin, :bin_path) do
          def initialize(repo_root:, mise_toml:, mise_bin:, ruby_bin:, bin_path:)
            super
          end
        end
      end

      class Install < Dry::CLI::Command
        include Helpers
        include GlobalOptions

        desc "Install the per-user launchd agent (writes the plist + bootstrap)"

        def call(plain: nil, json: nil, no_color: nil, quiet: nil, **)
          paths = CLI.make_paths
          paths.ensure!
          config = Config::Store.load(paths.config_file).success

          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          label = Launchd::Agent::DEFAULT_LABEL
          pp = plist_path(paths, label)

          # Relabel: if old-identity plist exists, bootout (benign-failure-tolerant)
          # and remove it before bootstrapping the new-label plist.
          old_pp = plist_path(paths, Migration::OLD_LABEL)
          if File.exist?(old_pp)
            old_agent = make_agent(label: Migration::OLD_LABEL)
            old_agent.uninstall
            File.delete(old_pp) if File.exist?(old_pp)
          end

          resolve = Resolve.detect(repo_root: Dir.pwd)
          xml = build_plist(resolve: resolve, config: config, paths: paths, label: label)
          FileUtils.mkdir_p(File.dirname(pp))
          File.write(pp, xml)

          agent = make_agent
          result = agent.install(pp)
          if result.failure?
            return fail_with(self, "bootstrap failed: #{format_failure(result.failure)}")
          end

          out.puts pastel.green("installed: #{pp}")
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end

      class Uninstall < Dry::CLI::Command
        include Helpers
        include GlobalOptions

        desc "Uninstall the per-user launchd agent (bootout + remove the plist)"

        def call(plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          paths = CLI.make_paths
          label = Launchd::Agent::DEFAULT_LABEL
          pp = plist_path(paths, label)

          agent = make_agent
          result = agent.uninstall
          # CF5 (Slice 5): the Agent maps a not-loaded bootout
          # (status 3 / "No such process") to Success — the
          # common case at a 6h refresh interval. A non-benign
          # bootout Failure (e.g. status 1 "Operation not
          # permitted") still surfaces here as a real failure
          # the operator needs to see. We still remove the
          # plist regardless (idempotent uninstall, Slice-4
          # gate G3): the bootout is the only best-effort step.
          if result.failure?
            err.puts "bootout reported: #{format_failure(result.failure)}"
          end

          if File.exist?(pp)
            File.delete(pp)
            out.puts pastel.green("removed plist: #{pp}")
          else
            out.puts pastel.yellow("plist not present: #{pp}")
          end

          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end

      class Start < Dry::CLI::Command
        include Helpers
        include GlobalOptions

        desc "Start the agent (bootstrap + enable)"

        def call(plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          paths = CLI.make_paths
          label = Launchd::Agent::DEFAULT_LABEL
          pp = plist_path(paths, label)

          agent = make_agent
          result = agent.start(pp)
          if result.failure?
            return fail_with(self, "start failed: #{format_failure(result.failure)}")
          end
          out.puts pastel.green("started: #{label}")
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end

      class Stop < Dry::CLI::Command
        include Helpers
        include GlobalOptions

        desc "Stop the agent (bootout + disable)"

        def call(plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          label = Launchd::Agent::DEFAULT_LABEL
          agent = make_agent
          result = agent.stop
          if result.failure?
            return fail_with(self, "stop failed: #{format_failure(result.failure)}")
          end
          out.puts pastel.green("stopped: #{label}")
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end

      class Restart < Dry::CLI::Command
        include Helpers
        include GlobalOptions

        desc "Restart the agent (kickstart -k)"

        def call(plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          label = Launchd::Agent::DEFAULT_LABEL
          agent = make_agent
          result = agent.restart
          if result.failure?
            return fail_with(self, "restart failed: #{format_failure(result.failure)}")
          end
          out.puts pastel.green("restarted: #{label}")
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end

      class Status < Dry::CLI::Command
        include Helpers
        include GlobalOptions

        desc "Print the agent's loaded/running/last-exit state"

        def call(plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          paths = CLI.make_paths
          old_pp = plist_path(paths, Migration::OLD_LABEL)
          if File.exist?(old_pp)
            err.puts pastel.yellow("warning: stale agent #{Migration::OLD_LABEL} detected; run `repo-tender daemon install` to upgrade")
          end

          label = Launchd::Agent::DEFAULT_LABEL
          agent = make_agent
          result = agent.status
          if result.failure?
            return fail_with(self, "status failed: #{format_failure(result.failure)}")
          end
          s = result.success
          out.puts pastel.cyan("label: #{label}")
          out.puts pastel.cyan("loaded: #{s[:loaded]}")
          out.puts pastel.cyan("running: #{s[:running]}")
          out.puts pastel.cyan("pid: #{s[:pid].inspect}")
          out.puts pastel.cyan("last_exit: #{s[:last_exit].inspect}")
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end
    end
  end
end

# Detect the runtime paths the plist needs. The repo-tender install path
# matters because the plist stores an absolute `bin_path` — that
# is the script launchd invokes. We resolve `bin_path` from the
# on-disk gem layout if we can, else fall back to the directory
# the daemon command was run from.
class RepoTender::CLI::Daemon::Helpers::Resolve
  # @param repo_root [String]  absolute path of the working directory (where mise.toml is expected)
  # @return [Resolve]
  def self.detect(repo_root:)
    mise_bin = detect_mise_bin
    ruby_bin = detect_ruby_bin(repo_root, mise_bin)
    bin_path = detect_bin_path(repo_root)
    mise_toml = File.join(repo_root, "mise.toml")
    new(repo_root: repo_root, mise_toml: mise_toml, mise_bin: mise_bin, ruby_bin: ruby_bin, bin_path: bin_path)
  end

  def self.detect_mise_bin
    path = ENV["REPO_TENDER_MISE_BIN"]
    return path if path && !path.empty?
    require "open3"
    out, _e, st = Open3.capture3("which", "mise")
    st.success? ? out.strip : "/opt/homebrew/bin/mise"
  end

  def self.detect_ruby_bin(repo_root, mise_bin)
    path = ENV["REPO_TENDER_RUBY_BIN"]
    return path if path && !path.empty?
    # `mise exec -- which ruby` — but we avoid spawning in tests;
    # production path goes through here.
    require "open3"
    out, _e, st = Open3.capture3(mise_bin, "exec", "--", "which", "ruby", chdir: repo_root)
    return out.strip if st.success? && !out.strip.empty?
    # Fall back to the system ruby (last resort).
    out, _e, st = Open3.capture3("which", "ruby")
    st.success? ? out.strip : "/usr/bin/ruby"
  end

  def self.detect_bin_path(repo_root)
    path = ENV["REPO_TENDER_BIN_PATH"]
    return path if path && !path.empty?
    # Prefer the on-disk dev bin at `<repo_root>/exe/repo-tender`
    # — it's what the human runs during testing, and the gem is
    # typically not `gem install`ed in a source checkout.
    dev = File.join(repo_root, "exe", "repo-tender")
    return dev if File.exist?(dev)
    # Next, an installed binary on PATH.
    require "open3"
    out, _e, st = Open3.capture3("which", "repo-tender")
    return out.strip if st.success? && !out.strip.empty?
    # Last resort: the installed gem's bin (raises if not installed).
    Gem.bin_path("repo-tender", "repo-tender")
  end
end

RepoTender::CLI::Registry.register "daemon" do |prefix|
  prefix.register "install", RepoTender::CLI::Daemon::Install
  prefix.register "uninstall", RepoTender::CLI::Daemon::Uninstall
  prefix.register "start", RepoTender::CLI::Daemon::Start
  prefix.register "stop", RepoTender::CLI::Daemon::Stop
  prefix.register "restart", RepoTender::CLI::Daemon::Restart
  prefix.register "status", RepoTender::CLI::Daemon::Status
end
