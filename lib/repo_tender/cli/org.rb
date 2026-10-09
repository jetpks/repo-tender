# frozen_string_literal: true

require "pastel"
require "dry/monads"
require "repo_tender/ui/mode"
require "repo_tender/cli/options"

module RepoTender
  module CLI
    # `org` command group: add / remove / list tracked orgs.
    # Same shape as `repo` but against `Config::OrgRef` (host + name
    # + two bool flags). The host defaults to "github.com" per
    # PRD §3.1 when omitted (so `org add socketry` works as well as
    # `org add github.com/socketry`).
    module Org
      module Helpers
        module_function

        # Parse an org ref string. Accepts "github.com/socketry" or
        # bare "socketry" (defaults host to github.com). Anything
        # with 3+ parts is rejected (org has only host + name).
        def parse_ref(name, include_archived: false, include_forks: false, ignored_repos: [])
          parts = name.to_s.split("/")
          case parts.length
          when 1
            org = parts[0]
            return Dry::Monads::Failure("invalid org reference: empty name in #{name.inspect}") if org.empty?
            Dry::Monads::Success(Config::OrgRef.new(
              host: Config::DEFAULT_HOST,
              name: org,
              include_archived: include_archived,
              include_forks: include_forks,
              ignored_repos: ignored_repos
            ))
          when 2
            host, n = parts
            return Dry::Monads::Failure("invalid org reference: empty host in #{name.inspect}") if host.empty?
            return Dry::Monads::Failure("invalid org reference: empty name in #{name.inspect}") if n.empty?
            Dry::Monads::Success(Config::OrgRef.new(
              host: host,
              name: n,
              include_archived: include_archived,
              include_forks: include_forks,
              ignored_repos: ignored_repos
            ))
          else
            Dry::Monads::Failure("invalid org reference: #{name.inspect} (expected \"<name>\" or \"<host>/<name>\")")
          end
        end

        def same_org?(a, b) = a.host == b.host && a.name == b.name
        def format_ref(o) = "#{o.host}/#{o.name}"
        def format_failure(f) = f.is_a?(Hash) ? f.inspect : f.to_s

        def format_ignored(o)
          return "" if o.ignored_repos.empty?
          " ignored_repos=#{o.ignored_repos.inspect}"
        end

        def fail_with(cmd, msg)
          cmd.send(:err).puts msg
          RepoTender::CLI.record_outcome(Outcome.new(exit_code: 1, message: msg))
        end
      end

      class Add < Dry::CLI::Command
        include Helpers
        include GlobalOptions

        desc "Add a tracked org (idempotent on host/name)"
        argument :name, required: true,
          desc: "Org identity as <name> or <host>/<name> (host defaults to github.com)"
        option :include_archived, type: :boolean, default: false,
          desc: "Include archived repos when expanding the org"
        option :include_forks, type: :boolean, default: false,
          desc: "Include forks when expanding the org"
        option :ignored_repos, type: :array, default: [],
          desc: "Repos to exclude from expansion (bare name or owner/name)"

        def call(name:, include_archived: false, include_forks: false, ignored_repos: [], plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          parsed = parse_ref(name,
            include_archived: include_archived,
            include_forks: include_forks,
            ignored_repos: ignored_repos)
          return fail_with(self, parsed.failure) if parsed.failure?

          new_ref = parsed.success
          paths = CLI.make_paths
          config = Config::Store.load(paths.config_file).success

          if config.orgs.any? { |o| same_org?(o, new_ref) }
            out.puts pastel.yellow("already tracked: #{format_ref(new_ref)}" \
              " (include_archived=#{new_ref.include_archived}, include_forks=#{new_ref.include_forks})" \
              "#{format_ignored(new_ref)}")
            return CLI.record_outcome(Outcome.new(exit_code: 0))
          end

          result = Config::Store.update(paths.config_file) do |c|
            Config::Store.with(c, orgs: c.orgs + [new_ref])
          end
          if result.failure?
            return fail_with(self, "failed to update config: #{format_failure(result.failure)}")
          end

          out.puts pastel.green("added: #{format_ref(new_ref)}" \
            " (include_archived=#{new_ref.include_archived}, include_forks=#{new_ref.include_forks})" \
            "#{format_ignored(new_ref)}")
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end

      class Remove < Dry::CLI::Command
        include Helpers
        include GlobalOptions

        desc "Remove a tracked org (host/name)"
        argument :name, required: true,
          desc: "Org identity as <name> or <host>/<name> (host defaults to github.com)"

        def call(name:, plain: nil, json: nil, no_color: nil, quiet: nil, **)
          # The flags don't affect the identity match for remove; we
          # match on (host, name) only. This matches the user's
          # expectation that "remove" targets the org, not the flag
          # combination they added it with.
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          parsed = parse_ref(name)
          return fail_with(self, parsed.failure) if parsed.failure?

          target = parsed.success
          paths = CLI.make_paths
          config = Config::Store.load(paths.config_file).success

          kept = config.orgs.reject { |o| same_org?(o, target) }
          if kept.size == config.orgs.size
            return fail_with(self, "not tracked: #{format_ref(target)}")
          end

          result = Config::Store.update(paths.config_file) do |c|
            Config::Store.with(c, orgs: kept)
          end
          if result.failure?
            return fail_with(self, "failed to update config: #{format_failure(result.failure)}")
          end

          out.puts pastel.green("removed: #{format_ref(target)}")
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end

      class List < Dry::CLI::Command
        include Helpers
        include GlobalOptions

        desc "List tracked orgs"

        def call(plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          paths = CLI.make_paths
          config = Config::Store.load(paths.config_file).success
          if config.orgs.empty?
            out.puts pastel.dim("(no tracked orgs)")
          else
            config.orgs.each do |o|
              out.puts pastel.cyan("#{o.host}/#{o.name}" \
                " (include_archived=#{o.include_archived}, include_forks=#{o.include_forks})" \
                "#{format_ignored(o)}")
            end
          end
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end
    end
  end
end

RepoTender::CLI::Registry.register "org" do |prefix|
  prefix.register "add", RepoTender::CLI::Org::Add
  prefix.register "remove", RepoTender::CLI::Org::Remove
  prefix.register "list", RepoTender::CLI::Org::List
end
