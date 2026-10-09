# frozen_string_literal: true

require "xdg"
require "fileutils"

module RepoTender
  # XDG-aware path resolution. Honors $XDG_CONFIG_HOME / $XDG_STATE_HOME
  # overrides (and a caller-supplied environment hash for testability);
  # otherwise falls back to the XDG defaults (~/.config, ~/.local/state).
  #
  # `base_dir` is the on-disk home for the evergreen clones
  # ($BASE/:host/:owner/:repo). It defaults to ~/src/evergreen and is
  # resolved from the config at call time (passed in as an argument here
  # so this module owns nothing about config storage).
  class Paths
    APP_NAME = "repo-tender"

    DEFAULT_BASE_DIR = File.expand_path("~/src/evergreen")

    def initialize(environment: ENV, base_dir: nil)
      @environment = environment
      @base_dir = base_dir
    end

    def config_home = xdg.config_home.to_s

    def state_home = xdg.state_home.to_s

    def config_dir = File.join(config_home, APP_NAME)

    def config_file = File.join(config_dir, "config.yaml")

    def state_dir = File.join(state_home, APP_NAME)

    def state_file = File.join(state_dir, "state.yaml")

    def log_dir = File.join(state_dir, "logs")

    # Per-user launchd agent directory. The user's
    # `~/Library/LaunchAgents/` (PRD §3.2; slice-4 Lane 01). The
    # path is resolved from the env's HOME so tests can inject a
    # temp HOME via `Paths.new(environment:)` and assert that
    # install/uninstall NEVER writes to the real
    # `~/Library/LaunchAgents` (gate G3).
    def launch_agents_dir
      home = @environment["HOME"] || Dir.home
      File.join(home, "Library", "LaunchAgents")
    end

    # Default `base_dir` is ~/src/evergreen. Callers may override by passing
    # one to the constructor (e.g. from loaded config).
    def base_dir
      @base_dir || DEFAULT_BASE_DIR
    end

    # Ensure the on-disk directories exist. The config file itself is
    # optional and created lazily by Config::Store; we only ensure parent
    # dirs. Idempotent.
    def ensure!
      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(state_dir)
      FileUtils.mkdir_p(log_dir)
      self
    end

    private

    def xdg
      @xdg ||= XDG::Environment.new(environment: @environment)
    end
  end
end
