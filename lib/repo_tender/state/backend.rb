# frozen_string_literal: true

require "dry/monads"

module RepoTender
  module State
    # Abstract state backend — the store seam behind Sync::Engine. The
    # engine asks THIS interface (not a file path) for the run-start
    # state, persists the merged end-of-run state through it, and takes
    # its run lock through it. State::YamlFile is the default impl (the
    # CLI's unchanged YAML state file); a host app supplies its own
    # backend (e.g. Postgres) by injecting `state_backend:` into
    # Sync::Engine. The seam's currency is the existing
    # State::Store::State / Repo / Org value objects — an app backend
    # maps its rows to/from them and keeps State::Store and State::Lock
    # public APIs unchanged. Mirrors Forge::Client's abstract style:
    # programmer errors raise; everything a backend does at runtime is
    # expressed as a Result.
    class Backend
      extend Dry::Monads[:result]

      # The state at run start. A missing/empty store is
      # Success(State with empty repos/orgs), not Failure — an empty
      # first run is a normal run.
      # @return [Dry::Monads::Result<State::Store::State>]
      def load
        raise NotImplementedError
      end

      # Persists the run's complete merged desired state. The engine
      # applies prune semantics BEFORE calling save; the backend writes
      # exactly what it is handed (never merges on its own).
      # @param state [State::Store::State]
      # @return [Dry::Monads::Result<State::Store::State>]
      def save(state)
        raise NotImplementedError
      end

      # Serializes the run. Yields only when the exclusive lock is
      # acquired and returns the block's result; returns the sentinel
      # State::Lock::NOT_ACQUIRED (without yielding) when another run
      # already holds it — overlapping runs must never write.
      # A host impl may use a DB advisory lock or a no-op for a
      # single-runner deployment.
      def with_exclusive_lock
        raise NotImplementedError
      end
    end
  end
end
