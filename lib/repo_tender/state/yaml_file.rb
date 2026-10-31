# frozen_string_literal: true

require "repo_tender/state/backend"
require "repo_tender/state/store"
require "repo_tender/state/lock"

module RepoTender
  module State
    # The default State::Backend: the YAML state file at
    # paths.state_file, unchanged from the CLI-only era. Pure
    # delegation — State::Store and State::Lock keep their public APIs
    # untouched (the CLI's status command and their tests consume them
    # directly). Constructed by Sync::Engine when no backend is
    # injected, or explicitly via `state_file:`.
    class YamlFile < State::Backend
      def initialize(state_file:)
        @state_file = state_file
      end

      def load
        Store.load(@state_file)
      end

      def save(state)
        Store.write(@state_file, state)
      end

      def with_exclusive_lock(&block)
        Lock.acquire(@state_file, &block)
      end
    end
  end
end
