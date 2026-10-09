# frozen_string_literal: true

require "repo_tender/shell_integration"

module RepoTender
  module CLI
    module Shell
      class Init < Dry::CLI::Command
        desc "Print shell integration script"
        argument :shell_name, required: true, desc: "Shell name (e.g. fish)"

        def call(shell_name:, **)
          out.puts ShellIntegration.for(shell_name)
          CLI.record_outcome(Outcome.new(exit_code: 0))
        rescue => e
          err.puts "repo-tender shell init: #{e.message}"
          CLI.record_outcome(Outcome.new(exit_code: 1))
        end
      end

      class Fish < Dry::CLI::Command
        desc "Manage fish shell integration: install, uninstall, path"
        argument :subcommand, required: false, desc: "install, uninstall, or path (default: install)"
        option :force, type: :boolean, default: false, desc: "Overwrite or remove existing shell files"

        def call(subcommand: "install", force: false, **)
          case subcommand
          when "install"
            result = ShellIntegration.install("fish", env: CLI.env, force: force)
            out.puts fish_install_message(result.fetch(:action), result.fetch(:path))
            out.puts fish_completions_install_message(result.fetch(:completions_action), result.fetch(:completions_path))
            out.puts "Restart fish to load the integration in this terminal: exec fish"
            CLI.record_outcome(Outcome.new(exit_code: 0))
          when "uninstall"
            result = ShellIntegration.uninstall("fish", env: CLI.env, force: force)
            out.puts fish_uninstall_message(result.fetch(:action), result.fetch(:path))
            out.puts fish_completions_uninstall_message(result.fetch(:completions_action), result.fetch(:completions_path))
            CLI.record_outcome(Outcome.new(exit_code: 0))
          when "path"
            out.puts "Function:    #{ShellIntegration.path_for("fish", env: CLI.env)}"
            out.puts "Completions: #{ShellIntegration.completions_path_for("fish", env: CLI.env)}"
            CLI.record_outcome(Outcome.new(exit_code: 0))
          else
            err.puts "Usage: repo-tender shell fish [install|uninstall|path]"
            CLI.record_outcome(Outcome.new(exit_code: 1))
          end
        rescue => e
          err.puts "repo-tender shell fish: #{e.message}"
          CLI.record_outcome(Outcome.new(exit_code: 1))
        end

        private

        def fish_install_message(action, path)
          case action
          when :unchanged then "Fish integration already installed: #{path}"
          when :updated then "Updated fish integration: #{path}"
          else "Installed fish integration: #{path}"
          end
        end

        def fish_uninstall_message(action, path)
          case action
          when :missing then "Fish integration was not installed: #{path}"
          else "Removed fish integration: #{path}"
          end
        end

        def fish_completions_install_message(action, path)
          case action
          when :unchanged then "Fish completions already installed: #{path}"
          when :updated then "Updated fish completions: #{path}"
          else "Installed fish completions: #{path}"
          end
        end

        def fish_completions_uninstall_message(action, path)
          case action
          when :missing then "Fish completions were not installed: #{path}"
          else "Removed fish completions: #{path}"
          end
        end
      end

      class Complete < Dry::CLI::Command
        desc "Print completion candidates"
        argument :kind, required: true, desc: "Completion kind"
        argument :extra, type: :array, required: false, desc: "Extra args for completion"

        def call(kind:, extra: [], **)
          case kind
          when "checkouts"
            begin
              paths = CLI.make_paths
              config = Config::Store.load(paths.config_file).success
              Nav.scan(config.base_dir).each { |e| out.puts e[:target] }
            rescue
              # Never raise on a completion call — missing/unparseable config is fine.
            end
            CLI.record_outcome(Outcome.new(exit_code: 0))
          when "shells"
            out.puts "fish"
            CLI.record_outcome(Outcome.new(exit_code: 0))
          else
            err.puts "Usage: repo-tender shell complete checkouts|shells"
            CLI.record_outcome(Outcome.new(exit_code: 1))
          end
        rescue => e
          err.puts "repo-tender shell complete: #{e.message}"
          CLI.record_outcome(Outcome.new(exit_code: 1))
        end
      end
    end
  end
end

RepoTender::CLI::Registry.register "shell" do |prefix|
  prefix.register "init", RepoTender::CLI::Shell::Init
  prefix.register "fish", RepoTender::CLI::Shell::Fish
  prefix.register "complete", RepoTender::CLI::Shell::Complete
end
