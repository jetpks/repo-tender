# frozen_string_literal: true

require "pastel"
require "dry/monads"
require "repo_tender/cli/options"
require "repo_tender/cloner"

module RepoTender
  module CLI
    # `clone` command: APFS COW copy of an evergreen repo into a working dir.
    # Resolves each NAME against config.base_dir and copies via cp -Rc.
    # Multiple names are processed independently; a per-name failure is
    # reported on err and does not abort the others. Exit code is 1 if any
    # name failed, else 0.
    class Clone < Dry::CLI::Command
      include GlobalOptions

      desc "Clone evergreen repo(s) into a working directory (APFS COW copy)"
      argument :names, type: :array, required: true,
        desc: "Repo name(s): bare name, owner/name, or host/owner/name"
      option :into, default: ".",
        desc: "Destination parent directory (default: current working directory)"

      def call(names:, into: ".", plain: nil, json: nil, no_color: nil, quiet: nil, **)
        mode = UI::Mode.resolve(
          flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
          env: CLI.env,
          out: out
        )
        pastel = Pastel.new(enabled: mode.color)

        paths = CLI.make_paths
        config = Config::Store.load(paths.config_file).success
        cloner = Cloner.new(base_dir: config.base_dir)

        any_failure = false
        names.each do |name|
          result = cloner.call(name: name, into: into)
          if result.success?
            dest = result.success
            out.puts pastel.green("cloned: #{name} → #{dest}")
          else
            err.puts result.failure
            any_failure = true
          end
        end

        CLI.record_outcome(Outcome.new(exit_code: any_failure ? 1 : 0))
      end
    end
  end
end

RepoTender::CLI::Registry.register "clone", RepoTender::CLI::Clone
