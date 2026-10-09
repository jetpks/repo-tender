# frozen_string_literal: true

module RepoTender
  module Sync
    # What one sync pass did.
    #
    # `state` is the merged whole-state that gets written to disk: it
    # carries a row for every repo ever synced, because build_new_state
    # starts from the previous state and merges this run's outcomes into
    # it. `processed` counts only the repos this run actually touched.
    #
    # The two diverge whenever the run is scoped (`sync --repo`) or the
    # state file already holds rows from earlier runs — which is why
    # callers wanting "how many repos did this run handle?" must read
    # `processed` and never `state.repos.size`.
    Report = Data.define(:state, :processed)
  end
end
