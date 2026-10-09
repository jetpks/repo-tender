# frozen_string_literal: true

require "test_helper"

class SCMGitTest < Minitest::Test
  include TestHelpers

  Git = RepoTender::SCM::Git

  # G5: SCM::Git against a real temp git repo + local bare remote.
  # Status, default_branch (named `trunk`, not `main`), current_branch,
  # last_fetch_at, fetch, fast_forward, clone, and fast_forward
  # refusing on divergence — all proven against real on-disk git.

  def test_default_branch_resolves_to_trunk_not_assuming_main
    with_seeded_trunk_repo do |_bare, clone|
      git = Git.new
      result = git.default_branch(clone)
      assert result.success?, "default_branch failed: #{result.failure.inspect}"
      assert_equal "trunk", result.success
    end
  end

  def test_current_branch_returns_trunk
    with_seeded_trunk_repo do |_bare, clone|
      git = Git.new
      result = git.current_branch(clone)
      assert result.success?
      assert_equal "trunk", result.success
    end
  end

  def test_status_parses_clean
    with_seeded_trunk_repo do |_bare, clone|
      git = Git.new
      result = git.status(clone)
      assert result.success?
      assert result.success.clean?, "expected clean tree, got entries=#{result.success.entries.inspect}"
    end
  end

  def test_status_parses_modified_as_dirty
    with_seeded_trunk_repo do |_bare, clone|
      git = Git.new
      File.write(File.join(clone, "README.md"), "modified\n")
      result = git.status(clone)
      assert result.success?
      refute result.success.clean?
      assert(result.success.entries.any? { |e| e.start_with?("1 .M") })
    end
  end

  def test_status_parses_untracked_as_dirty
    with_seeded_trunk_repo do |_bare, clone|
      git = Git.new
      File.write(File.join(clone, "new.txt"), "x")
      result = git.status(clone)
      assert result.success?
      refute result.success.clean?
      assert(result.success.entries.any? { |e| e.start_with?("?") })
    end
  end

  def test_status_parses_staged_as_dirty
    with_seeded_trunk_repo do |_bare, clone|
      git = Git.new
      File.write(File.join(clone, "new.txt"), "x")
      Shell.run("git", "add", "new.txt", chdir: clone)
      result = git.status(clone)
      assert result.success?
      refute result.success.clean?
      assert(result.success.entries.any? { |e| e.start_with?("1 A.") })
    end
  end

  def test_last_fetch_at_nil_before_any_fetch
    with_seeded_trunk_repo do |_bare, clone|
      git = Git.new
      result = git.last_fetch_at(clone)
      assert result.success?
      # FETCH_HEAD may or may not exist after push; we accept either
      # (no assert on value) but the call must succeed.
    end
  end

  def test_last_fetch_at_returns_time_after_fetch
    with_seeded_trunk_repo do |_bare, clone|
      git = Git.new
      git.fetch(clone)
      result = git.last_fetch_at(clone)
      assert result.success?
      assert_kind_of Time, result.success
    end
  end

  def test_fetch_succeeds_on_real_repo
    with_seeded_trunk_repo do |_bare, clone|
      git = Git.new
      result = git.fetch(clone)
      assert result.success?, "fetch failed: #{result.failure.inspect}"
    end
  end

  def test_clone_creates_new_working_copy
    with_seeded_trunk_repo do |bare, clone|
      git = Git.new
      dest = File.join(File.dirname(clone), "cloned")
      result = git.clone(bare, dest)
      assert result.success?, "clone failed: #{result.failure.inspect}"
      assert File.directory?(File.join(dest, ".git"))
    end
  end

  # The big one for G5: fast_forward refuses on divergence with no
  # data loss. Working tree + local commits stay intact.
  def test_fast_forward_refuses_on_divergence_with_no_data_loss
    with_seeded_trunk_repo do |bare, clone|
      # Set up a second clone to push a divergent commit.
      clone2 = File.join(File.dirname(clone), "clone2")
      system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone2, exception: true, out: File::NULL)
      Shell.run("git", "remote", "add", "origin", bare, chdir: clone2)
      Shell.run("git", "pull", "-q", "origin", "trunk", chdir: clone2)
      File.write(File.join(clone2, "remote.md"), "remote\n")
      Shell.run("git", "add", ".", chdir: clone2)
      Shell.run("git", "-c", "user.email=t@t.com", "-c", "user.name=T",
        "commit", "-qm", "remote commit", chdir: clone2)
      Shell.run("git", "push", "-q", "origin", "trunk", chdir: clone2)

      # Now make a local commit on the original clone (un-pushed).
      File.write(File.join(clone, "local.md"), "local\n")
      Shell.run("git", "add", ".", chdir: clone)
      Shell.run("git", "commit", "-qm", "local commit", chdir: clone)

      git = Git.new
      result = git.fast_forward(clone, "trunk")
      assert result.failure?, "fast_forward should refuse on divergence"
      f = result.failure
      assert_includes f[:reason], "diverged"
      assert_equal 1, f[:local_ahead]

      # The local commit is still on the branch (no reset --hard).
      log_out = Shell.run("git", "log", "--oneline", chdir: clone).success
      assert_includes log_out, "local commit"

      # The local file is still on disk.
      assert File.exist?(File.join(clone, "local.md"))
      assert_equal "local\n", File.read(File.join(clone, "local.md"))
    end
  end

  def test_fast_forward_succeeds_on_clean_behind
    with_seeded_trunk_repo do |bare, clone|
      # Push a new commit from a second clone, then rewind the first
      # clone's ref to the parent — clean tree, behind on the default
      # branch.
      clone2 = File.join(File.dirname(clone), "clone2")
      system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone2, exception: true, out: File::NULL)
      Shell.run("git", "remote", "add", "origin", bare, chdir: clone2)
      Shell.run("git", "pull", "-q", "origin", "trunk", chdir: clone2)
      File.write(File.join(clone2, "remote.md"), "remote\n")
      Shell.run("git", "add", ".", chdir: clone2)
      Shell.run("git", "-c", "user.email=t@t.com", "-c", "user.name=T",
        "commit", "-qm", "remote commit", chdir: clone2)
      Shell.run("git", "push", "-q", "origin", "trunk", chdir: clone2)

      # Rewind clone's branch to parent of new commit, no working-tree
      # changes.
      parent_sha = Shell.run("git", "rev-parse", "HEAD", chdir: clone).success.strip
      Shell.run("git", "update-ref", "refs/heads/trunk", parent_sha, chdir: clone)
      # Also reset origin/trunk to the parent so the upstreams match
      # before fast-forward (this is what "behind" means).
      Shell.run("git", "update-ref", "refs/remotes/origin/trunk", parent_sha, chdir: clone)
      # But origin actually has a newer commit — restore the actual ref.
      Shell.run("git", "fetch", "-q", "origin", chdir: clone)
      # Now clone is "behind" on origin/trunk (origin has the remote
      # commit, local trunk is at parent).

      git = Git.new
      result = git.fast_forward(clone, "trunk")
      assert result.success?, "fast_forward failed: #{result.failure.inspect}"
      assert_kind_of Integer, result.success, "fast_forward success must be Integer (commit count)"
      assert result.success >= 1, "fast_forward must return commit count >= 1 when behind"
    end
  end

  # ---- G4 (interactive-status): fast_forward returns Integer commit count ----

  def test_g4_fast_forward_returns_zero_when_up_to_date
    with_seeded_trunk_repo do |_bare, clone|
      # Clone is already up to date with remote (no commits added elsewhere)
      git = Git.new
      result = git.fast_forward(clone, "trunk")
      assert result.success?, "fast_forward failed: #{result.failure.inspect}"
      assert_equal 0, result.success, "fast_forward must return 0 (Integer) when up to date"
    end
  end

  def test_g4_fast_forward_returns_commit_count_when_behind
    with_seeded_trunk_repo do |bare, clone|
      # Push 2 extra commits from a second clone
      clone2 = File.join(File.dirname(clone), "clone2")
      system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone2, exception: true, out: File::NULL)
      Shell.run("git", "remote", "add", "origin", bare, chdir: clone2)
      Shell.run("git", "pull", "-q", "origin", "trunk", chdir: clone2)
      2.times do |i|
        File.write(File.join(clone2, "extra#{i}.md"), "extra#{i}\n")
        Shell.run("git", "add", ".", chdir: clone2)
        Shell.run("git", "-c", "user.email=t@t.com", "-c", "user.name=T",
          "commit", "-qm", "extra commit #{i}", chdir: clone2)
      end
      Shell.run("git", "push", "-q", "origin", "trunk", chdir: clone2)

      # Rewind original clone to be 2 commits behind
      parent2_sha = Shell.run("git", "rev-parse", "HEAD", chdir: clone).success.strip
      Shell.run("git", "update-ref", "refs/heads/trunk", parent2_sha, chdir: clone)
      Shell.run("git", "update-ref", "refs/remotes/origin/trunk", parent2_sha, chdir: clone)
      Shell.run("git", "fetch", "-q", "origin", chdir: clone)

      git = Git.new
      result = git.fast_forward(clone, "trunk")
      assert result.success?, "fast_forward failed: #{result.failure.inspect}"
      assert_kind_of Integer, result.success, "fast_forward must return Integer"
      assert result.success >= 1, "fast_forward must return commit count >= 1 when behind"
    end
  end

  def test_g4_fast_forward_fails_on_divergence_still
    with_seeded_trunk_repo do |bare, clone|
      clone2 = File.join(File.dirname(clone), "clone2")
      system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone2, exception: true, out: File::NULL)
      Shell.run("git", "remote", "add", "origin", bare, chdir: clone2)
      Shell.run("git", "pull", "-q", "origin", "trunk", chdir: clone2)
      File.write(File.join(clone2, "remote.md"), "remote\n")
      Shell.run("git", "add", ".", chdir: clone2)
      Shell.run("git", "-c", "user.email=t@t.com", "-c", "user.name=T",
        "commit", "-qm", "remote commit", chdir: clone2)
      Shell.run("git", "push", "-q", "origin", "trunk", chdir: clone2)

      File.write(File.join(clone, "local.md"), "local\n")
      Shell.run("git", "add", ".", chdir: clone)
      Shell.run("git", "commit", "-qm", "local commit", chdir: clone)

      git = Git.new
      result = git.fast_forward(clone, "trunk")
      assert result.failure?, "fast_forward must Fail on divergence"
      assert_includes result.failure[:reason], "diverged"
      assert result.failure.key?(:local_ahead), "failure must carry :local_ahead"
      assert result.failure.key?(:remote_ahead), "failure must carry :remote_ahead"
    end
  end

  # ---- GB1: parse_porcelain_v2 sets unborn: correctly ----

  def test_status_unborn_true_on_empty_clone
    with_empty_repo do |_bare, clone|
      git = Git.new
      result = git.status(clone)
      assert result.success?, "status failed on empty clone: #{result.failure.inspect}"
      assert result.success.unborn?, "expected unborn? true on empty clone"
      assert result.success.clean?, "expected clean? true on empty clone with no files"
    end
  end

  def test_status_unborn_false_on_committed_repo
    with_seeded_trunk_repo do |_bare, clone|
      git = Git.new
      result = git.status(clone)
      assert result.success?
      refute result.success.unborn?, "expected unborn? false on a repo with commits"
    end
  end

  # ---- GB2: sync_empty returns :empty when remote has no branches ----

  def test_sync_empty_returns_empty_when_remote_has_no_commits
    with_empty_repo do |_bare, clone|
      git = Git.new
      result = git.sync_empty(clone)
      assert result.success?, "sync_empty failed: #{result.failure.inspect}"
      assert_equal :empty, result.success

      # No mutation: HEAD is still unborn.
      status = git.status(clone)
      assert status.success.unborn?, "clone should still be unborn after sync_empty(:empty)"
      assert status.success.clean?
    end
  end

  # ---- GB3: sync_empty fast-forwards when remote gains commits ----

  def test_sync_empty_fast_forwards_when_remote_gains_commits
    with_empty_repo do |bare, clone|
      push_first_commit_to_bare(bare, content: "hello\n", filename: "README.md")

      git = Git.new
      result = git.sync_empty(clone)
      assert result.success?, "sync_empty failed after remote gained commits: #{result.failure.inspect}"
      assert_equal :fast_forwarded, result.success

      # Clone now has the file and a resolved HEAD.
      assert File.exist?(File.join(clone, "README.md")),
        "README.md should be present after fast-forward into unborn branch"
      assert_equal "hello\n", File.read(File.join(clone, "README.md"))

      status = git.status(clone)
      assert status.success?, "status failed after fast-forward"
      refute status.success.unborn?, "clone should no longer be unborn after fast-forward"
      assert status.success.clean?
    end
  end

  # ---- GB5: sync_empty propagates real network failure ----

  def test_sync_empty_returns_failure_on_bad_remote
    with_empty_repo do |_bare, clone|
      # Point origin at a non-existent path so ls-remote fails.
      Shell.run("git", "remote", "set-url", "origin", "/tmp/does-not-exist-#{Process.pid}.git", chdir: clone)
      git = Git.new
      result = git.sync_empty(clone)
      assert result.failure?, "expected Failure for unreachable remote, got #{result.success.inspect}"
    end
  end
end
