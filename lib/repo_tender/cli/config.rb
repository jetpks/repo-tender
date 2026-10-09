# frozen_string_literal: true

require "pastel"
require "yaml"
require "repo_tender/ui/mode"
require "repo_tender/cli/options"

module RepoTender
  module CLI
    # `config` command group: path / show.
    module ConfigCmd
      class Path < Dry::CLI::Command
        include GlobalOptions

        desc "Print the resolved config file path (honors $XDG_CONFIG_HOME)"

        def call(plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          paths = CLI.make_paths
          out.puts pastel.cyan(paths.config_file)
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end

      class Show < Dry::CLI::Command
        include GlobalOptions

        desc "Print the effective (validated, defaults-applied) config as YAML"

        def call(plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          paths = CLI.make_paths
          config = Config::Store.load(paths.config_file).success
          # Emit via the store's own emit() so the format matches
          # what `config.yaml` looks like on disk (stable key order
          # per Slice 1's emit implementation). This makes
          # `config show` a faithful round-trip preview.
          out.puts pastel.cyan(Config::Store.emit(config.to_h).chomp)
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end
    end
  end
end

# `config` is the name of both our config-store module (Config) and
# the CLI command group. We register under a different module name
# (ConfigCmd) to avoid the constant clash, then alias the
# registration key as "config".
RepoTender::CLI::Registry.register "config" do |prefix|
  prefix.register "path", RepoTender::CLI::ConfigCmd::Path
  prefix.register "show", RepoTender::CLI::ConfigCmd::Show
end
