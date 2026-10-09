# frozen_string_literal: true

require "pastel"
require "repo_tender/ui/mode"
require "repo_tender/cli/options"

module RepoTender
  module CLI
    # `status` command: render a per-repo evergreen table from
    # State::Store. Per G5, the rows must include each repo key
    # with status, last_synced_at, and default_branch.
    module Status
      class Show < Dry::CLI::Command
        include GlobalOptions

        STATUS_COLORS = {
          "clean" => :green,
          "dirty" => :yellow,
          "diverged" => :yellow,
          "wrong_branch" => :yellow,
          "detached" => :yellow,
          "error" => :red
        }.freeze

        desc "Show the per-repo evergreen status table (from $XDG_STATE_HOME/repo-tender/state.yaml)"

        def call(plain: nil, json: nil, no_color: nil, quiet: nil, **)
          mode = UI::Mode.resolve(
            flags: {plain: plain, json: json, no_color: no_color, quiet: quiet},
            env: CLI.env,
            out: out
          )
          pastel = Pastel.new(enabled: mode.color)

          paths = CLI.make_paths
          state = State::Store.load(paths.state_file).success

          if state.repos.empty?
            out.puts "(no repos in state — run `repo-tender sync` to populate)"
            return CLI.record_outcome(Outcome.new(exit_code: 0))
          end

          # Tab-separated columns. The G5 assertion is on captured
          # stdout containing each repo key and its status string —
          # tab-separated is the most assertion-friendly (no width
          # padding complexity, no ANSI codes).
          out.puts ["REPO", "STATUS", "DEFAULT_BRANCH", "LAST_SYNCED_AT", "LAST_FETCH_AT"].join("\t")
          state.repos.keys.sort.each do |key|
            r = state.repos[key]
            status_str = r.status.to_s
            color = STATUS_COLORS[status_str]
            styled_status = color ? pastel.decorate(status_str, color) : status_str
            out.puts [
              key,
              styled_status,
              r.default_branch.to_s,
              format_time(r.last_synced_at),
              format_time(r.last_fetch_at)
            ].join("\t")
          end
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end

        private

        def format_time(t)
          return "" if t.nil?
          t.respond_to?(:iso8601) ? t.iso8601 : t.to_s
        end
      end
    end
  end
end

RepoTender::CLI::Registry.register "status", RepoTender::CLI::Status::Show
