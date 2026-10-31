# frozen_string_literal: true

require "fileutils"
require "time"
require "repo_tender/shell"
require "dry/monads"

module RepoTender
  module SCM
    # Bare-mirror operations — a SIBLING of SCM::Git, not methods on
    # SCM::Client: a `git clone --mirror` has no working tree, so the
    # evergreen interface (status/current_branch/switch/…) fits it not
    # at all. The mirror invariant is "all refs, all objects, nothing
    # checked out": keeping a mirror fresh is `remote update --prune`,
    # never a merge or a checkout. POSIX git only (the server is
    # Debian); subprocess work via Shell.run under `chdir:`; every
    # method returns a Result — failures are Failures, never raises
    # (programmer error excepted, per AGENTS.md).
    class Mirror
      extend Dry::Monads[:result]

      # `git clone --mirror <url> <dest>` — a bare mirror with
      # remote.origin.mirror=true and all refs copied verbatim.
      # Shape parity with SCM::Git#clone.
      def clone(url, dest)
        parent = File.dirname(dest)
        FileUtils.mkdir_p(parent)
        result = Shell.run("git", "clone", "--mirror", url, dest)
        if result.success?
          Dry::Monads::Success(dest)
        else
          Dry::Monads::Failure({url: url, dest: dest, stderr: result.failure[:stderr]})
        end
      end

      # Refresh a mirror in place: new origin refs appear, deleted
      # origin refs are pruned. Creates <path>/FETCH_HEAD (absent
      # after a fresh clone).
      def update(path)
        result = Shell.run("git", "remote", "update", "--prune", chdir: path)
        if result.success?
          Dry::Monads::Success(path)
        else
          Dry::Monads::Failure({
            path: path,
            reason: "git remote update --prune failed",
            stderr: result.failure[:stderr]
          })
        end
      end

      # Fetch-freshness for the bare layout: top-level <path>/FETCH_HEAD
      # (no `.git` segment — the repo itself is bare). Absent after a
      # fresh clone, so a never-updated mirror reads as stale — the
      # same posture as SCM::Git#last_fetch_at's absent FETCH_HEAD.
      def last_fetch_at(path)
        fetch_head = File.join(path, "FETCH_HEAD")
        return Dry::Monads::Success(nil) unless File.exist?(fetch_head)
        Dry::Monads::Success(Time.at(File.mtime(fetch_head).to_i))
      end

      # The clone-vs-update discriminator: true iff the path is a git
      # repo AND bare AND configured as an origin mirror. Missing
      # path / not a repo / either probe answering no → false; a
      # Failure only for a real probe error (e.g. the subprocess
      # itself blowing up) — a git exit code is an answer, not an
      # error.
      def mirror?(path)
        return Dry::Monads::Success(false) unless File.directory?(path)

        bare = Shell.run("git", "rev-parse", "--is-bare-repository", chdir: path)
        return Dry::Monads::Success(false) if bare.failure?
        return Dry::Monads::Success(false) unless bare.success.strip == "true"

        mirror_config = Shell.run("git", "config", "--get", "remote.origin.mirror", chdir: path)
        return Dry::Monads::Success(false) if mirror_config.failure?
        return Dry::Monads::Success(false) unless mirror_config.success.strip == "true"

        Dry::Monads::Success(true)
      rescue => e
        Dry::Monads::Failure({path: path, reason: "#{e.class}: #{e.message}"})
      end
    end
  end
end
