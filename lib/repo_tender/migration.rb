# frozen_string_literal: true

require "fileutils"

module RepoTender
  # One-shot data-preserving migration from the absorbed identity back to
  # `repo-tender` (the engine was absorbed into space-architect v8.0.0 under
  # its own namespace and binary name; the constants below are that foreign
  # identity's on-disk names, kept verbatim so the move is lossless).
  # Invoked from CLI.run before dispatch on every run; all operations are
  # idempotent so repeated invocations are safe.
  class Migration
    OLD_APP_NAME = "space-src"
    OLD_LABEL = "io.github.jetpks.space-src.sync"

    # Move old-identity XDG dirs to new-identity locations if the old
    # ones exist and the new ones do not (no-clobber — no data loss).
    # Print a one-line notice to `err` only when something is actually
    # moved. Also warn if the old-label launchd plist is still present
    # so the user knows to run `repo-tender daemon install`.
    def self.run(paths:, err:)
      moved = false

      old_config = File.join(paths.config_home, OLD_APP_NAME)
      new_config = paths.config_dir
      if File.directory?(old_config) && !File.exist?(new_config)
        FileUtils.mv(old_config, new_config)
        moved = true
      end

      old_state = File.join(paths.state_home, OLD_APP_NAME)
      new_state = paths.state_dir
      if File.directory?(old_state) && !File.exist?(new_state)
        FileUtils.mv(old_state, new_state)
        moved = true
      end

      err.puts "repo-tender: migrated config/state from #{OLD_APP_NAME}" if moved

      old_plist = File.join(paths.launch_agents_dir, "#{OLD_LABEL}.plist")
      if File.exist?(old_plist)
        err.puts "repo-tender: stale launchd agent found (#{OLD_LABEL}); run `repo-tender daemon install` to upgrade"
      end
    end
  end
end
