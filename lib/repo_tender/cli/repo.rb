# frozen_string_literal: true

require "pastel"
require "dry/monads"
require "repo_tender/ui/mode"
require "repo_tender/cli/options"

module RepoTender
  module CLI
    # `repo` command group: add / remove / list tracked repos.
    # Backed by Config::Store (the on-disk config.yaml is the
    # source of truth — the CLI is just the CRUD interface).
    module Repo
      # Shared ref parser + formatters used by Add and Remove. Kept
      # in a module-level Helpers so the parsing rules live in one
      # place (the "invalid repo reference" message must be identical
      # across add/remove for G3 consistency).
      module Helpers
        module_function

        def parse_ref(ref)
          parts = ref.to_s.split("/")
          return Dry::Monads::Failure("invalid repo reference: #{ref.inspect} (expected host/owner/name)") if parts.length != 3
          host, owner, name = parts
          return Dry::Monads::Failure("invalid repo reference: empty host in #{ref.inspect}") if host.empty?
          return Dry::Monads::Failure("invalid repo reference: empty owner in #{ref.inspect}") if owner.empty?
          return Dry::Monads::Failure("invalid repo reference: empty name in #{ref.inspect}") if name.empty?
          Dry::Monads::Success(Config::RepoRef.new(host: host, owner: owner, name: name))
        end

        def same_repo?(a, b)
          a.host == b.host && a.owner == b.owner && a.name == b.name
        end

        def format_ref(r) = "#{r.host}/#{r.owner}/#{r.name}"

        def format_failure(f) = f.is_a?(Hash) ? f.inspect : f.to_s

        def fail_with(cmd, msg)
          cmd.send(:err).puts msg
          RepoTender::CLI.record_outcome(Outcome.new(exit_code: 1, message: msg))
        end
      end

      # Add a tracked repo. Idempotent on the (host, owner, name)
      # triple: adding the same ref twice prints "already tracked"
      # and exits 0 (does NOT write a duplicate).
      class Add < Dry::CLI::Command
        include Helpers
        include GlobalOptions

        desc "Add a tracked repo (idempotent on host/owner/name)"
        argument :ref, required: true,
          desc: "Repo identity as host/owner/name (e.g. github.com/ruby/ruby)"

        def call(ref:, plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          parsed = parse_ref(ref)
          return fail_with(self, parsed.failure) if parsed.failure?

          new_ref = parsed.success
          paths = CLI.make_paths
          config = Config::Store.load(paths.config_file).success

          if config.repos.any? { |r| same_repo?(r, new_ref) }
            out.puts pastel.yellow("already tracked: #{format_ref(new_ref)}")
            return CLI.record_outcome(Outcome.new(exit_code: 0))
          end

          result = Config::Store.update(paths.config_file) do |c|
            Config::Store.with(c, repos: c.repos + [new_ref])
          end

          if result.failure?
            return fail_with(self, "failed to update config: #{format_failure(result.failure)}")
          end

          out.puts pastel.green("added: #{format_ref(new_ref)}")
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end

      # Remove a tracked repo. Exits 0 with a clear message if the
      # ref was present; exits 1 with "not tracked" if it wasn't
      # (and the config is untouched in that case).
      class Remove < Dry::CLI::Command
        include Helpers
        include GlobalOptions

        desc "Remove a tracked repo (host/owner/name)"
        argument :ref, required: true,
          desc: "Repo identity as host/owner/name (e.g. github.com/ruby/ruby)"

        def call(ref:, plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          parsed = parse_ref(ref)
          return fail_with(self, parsed.failure) if parsed.failure?

          target = parsed.success
          paths = CLI.make_paths
          config = Config::Store.load(paths.config_file).success

          kept = config.repos.reject { |r| same_repo?(r, target) }
          if kept.size == config.repos.size
            return fail_with(self, "not tracked: #{format_ref(target)}")
          end

          result = Config::Store.update(paths.config_file) do |c|
            Config::Store.with(c, repos: kept)
          end
          if result.failure?
            return fail_with(self, "failed to update config: #{format_failure(result.failure)}")
          end

          out.puts pastel.green("removed: #{format_ref(target)}")
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end

      # List tracked repos. One per line: "host/owner/name".
      class List < Dry::CLI::Command
        include GlobalOptions

        desc "List tracked repos"

        def call(plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          paths = CLI.make_paths
          config = Config::Store.load(paths.config_file).success
          if config.repos.empty?
            out.puts pastel.dim("(no tracked repos)")
          else
            config.repos.each do |r|
              out.puts pastel.cyan("#{r.host}/#{r.owner}/#{r.name}")
            end
          end
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end
    end
  end
end

# Register the `repo` group + its subcommands. The block's `prefix`
# is a Dry::CLI::Registry::Prefix proxy that namespaces the
# subcommand names under "repo".
RepoTender::CLI::Registry.register "repo" do |prefix|
  prefix.register "add", RepoTender::CLI::Repo::Add
  prefix.register "remove", RepoTender::CLI::Repo::Remove
  prefix.register "list", RepoTender::CLI::Repo::List
end
