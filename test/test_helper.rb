# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "async"
require "mutant/minitest/coverage"

require "repo_tender"

module TestHelpers
  Shell = RepoTender::Shell

  # Run the given block in a fresh temp directory that is the
  # effective HOME for XDG resolution. Yields (env_hash, home_dir).
  def with_temp_home
    Dir.mktmpdir("repo-tender-test-") do |home|
      env = {
        "HOME" => home,
        "XDG_CONFIG_HOME" => File.join(home, ".config"),
        "XDG_STATE_HOME" => File.join(home, ".local", "state"),
        "XDG_CACHE_HOME" => File.join(home, ".cache")
      }
      env.each { |k, v| FileUtils.mkdir_p(v) }
      yield(env, home)
    end
  end

  # Wrap a temp HOME with XDG defaults created. Yields the
  # XDG-overridden environment hash plus a fresh Paths instance.
  def with_paths(base_dir: nil)
    with_temp_home do |env, _|
      yield(env, RepoTender::Paths.new(environment: env, base_dir: base_dir))
    end
  end

  # Run the block inside a Sync{} task (Shell requires one).
  def in_async(&block)
    Sync(&block)
  end

  # A bare remote (`trunk`) + a clone with author identity already
  # configured — built once per process via `git init`/`config`
  # subprocesses, then stamped out per test with a plain file copy.
  # `with_trunk_repo` and `with_empty_repo` both start from this same
  # shape (neither has any commits yet); real git still does every
  # subsequent remote-add/fetch/add/commit/push a test performs. `origin`
  # is added fresh per copy (not baked in) because callers routinely
  # `cp_r` the clone to a different final location while the bare stays
  # put, which would strand a baked-in relative remote URL.
  def self.bare_and_clone_template
    @bare_and_clone_template ||= begin
      dir = Dir.mktmpdir("repo-tender-git-template-")
      bare = File.join(dir, "bare.git")
      clone = File.join(dir, "clone")
      system("git", "init", "-b", "trunk", "--bare", bare, exception: true, out: File::NULL)
      system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone, exception: true, out: File::NULL)
      system("git", "-C", clone, "config", "user.email", "test@example.com", exception: true, out: File::NULL)
      system("git", "-C", clone, "config", "user.name", "Test", exception: true, out: File::NULL)
      dir
    end
  end

  # A bare remote (`trunk`) + a clone with the initial commit already
  # pushed — built once per process, stamped out per test with `cp_r`.
  # README.md ("hello\n") is committed and pushed; `origin` is stored in
  # the clone's config pointing at the template's bare. After cp_r,
  # callers run `git remote set-url origin <new_bare>` (1 spawn) instead
  # of the add+commit+push chain (3 spawns).
  def self.seeded_trunk_template
    @seeded_trunk_template ||= begin
      dir = Dir.mktmpdir("repo-tender-seeded-trunk-template-")
      bare = File.join(dir, "bare.git")
      clone = File.join(dir, "clone")
      system("git", "init", "-b", "trunk", "--bare", bare, exception: true, out: File::NULL)
      system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone, exception: true, out: File::NULL)
      system("git", "-C", clone, "config", "user.email", "test@example.com", exception: true, out: File::NULL)
      system("git", "-C", clone, "config", "user.name", "Test", exception: true, out: File::NULL)
      system("git", "-C", clone, "remote", "add", "origin", bare, exception: true, out: File::NULL)
      File.write(File.join(clone, "README.md"), "hello\n")
      system("git", "-C", clone, "add", ".", exception: true, out: File::NULL)
      system("git", "-C", clone, "commit", "-qm", "initial", exception: true, out: File::NULL)
      system("git", "-C", clone, "push", "-q", "-u", "origin", "trunk", exception: true, out: File::NULL)
      dir
    end
  end

  # A plain working dir with README.md ("hello\n") already committed —
  # built once per process, stamped out per test with `cp_r`. The caller
  # adds the remote and pushes (1 spawn) without the add+commit overhead.
  def self.committed_seeder_template
    @committed_seeder_template ||= begin
      dir = Dir.mktmpdir("repo-tender-committed-seeder-template-")
      seeder = File.join(dir, "seeder")
      system("git", "-c", "init.defaultBranch=trunk", "init", "-q", seeder, exception: true, out: File::NULL)
      system("git", "-C", seeder, "config", "user.email", "test@example.com", exception: true, out: File::NULL)
      system("git", "-C", seeder, "config", "user.name", "Test", exception: true, out: File::NULL)
      File.write(File.join(seeder, "README.md"), "hello\n")
      system("git", "-C", seeder, "add", ".", exception: true, out: File::NULL)
      system("git", "-C", seeder, "commit", "-qm", "first commit", exception: true, out: File::NULL)
      dir
    end
  end

  # Set up a real bare git remote + a working clone on disk.
  # The bare remote's default branch is `trunk` (per gate G5, the test
  # must NOT assume `main`). Yields paths to the bare and the clone.
  def with_trunk_repo
    Dir.mktmpdir("repo-tender-git-") do |parent|
      fixture = File.join(parent, "repo")
      FileUtils.cp_r(TestHelpers.bare_and_clone_template, fixture)
      bare = File.join(fixture, "bare.git")
      clone = File.join(fixture, "clone")
      in_async do
        Shell.run("git", "remote", "add", "origin", bare, chdir: clone)
        yield(bare, clone)
      end
    end
  end

  # Like `with_trunk_repo` but with the initial commit already baked in —
  # README.md ("hello\n") is committed and pushed. Callers that used
  # `with_trunk_repo { seed_initial_commit(clone); … }` can switch to this
  # and drop the `seed_initial_commit` call (saves 3 git spawns per test).
  def with_seeded_trunk_repo
    Dir.mktmpdir("repo-tender-git-") do |parent|
      fixture = File.join(parent, "repo")
      FileUtils.cp_r(TestHelpers.seeded_trunk_template, fixture)
      bare = File.join(fixture, "bare.git")
      clone = File.join(fixture, "clone")
      in_async do
        Shell.run("git", "remote", "set-url", "origin", bare, chdir: clone)
        yield(bare, clone)
      end
    end
  end

  # Make an initial commit on a clone and push it to its bare remote,
  # establishing a real "trunk" branch. Returns nothing; the caller
  # operates on the clone in the same `in_async` block.
  def seed_initial_commit(clone, content: "hello\n", filename: "README.md", message: "initial")
    in_async do
      File.write(File.join(clone, filename), content)
      Shell.run("git", "add", ".", chdir: clone)
      Shell.run("git", "commit", "-qm", message, chdir: clone)
      Shell.run("git", "push", "-q", "-u", "origin", "trunk", chdir: clone)
    end
  end

  # Set up a real EMPTY bare git remote + a working clone with zero commits.
  # The bare remote's default branch is `trunk` (consistent with
  # with_trunk_repo). The clone has an unborn HEAD — no commits exist
  # anywhere. Yields paths to the bare and the clone inside an in_async
  # block (Shell.run is available throughout).
  def with_empty_repo
    Dir.mktmpdir("repo-tender-empty-") do |parent|
      fixture = File.join(parent, "repo")
      FileUtils.cp_r(TestHelpers.bare_and_clone_template, fixture)
      bare = File.join(fixture, "bare.git")
      clone = File.join(fixture, "clone")
      in_async do
        Shell.run("git", "remote", "add", "origin", bare, chdir: clone)
        yield(bare, clone)
      end
    end
  end

  # A plain git working dir (init + author identity, no remote — the
  # bare remote to push to varies per call) built once per process.
  def self.seeder_template
    @seeder_template ||= begin
      dir = Dir.mktmpdir("repo-tender-git-seeder-template-")
      seeder = File.join(dir, "seeder")
      system("git", "-c", "init.defaultBranch=trunk", "init", "-q", seeder, exception: true, out: File::NULL)
      system("git", "-C", seeder, "config", "user.email", "test@example.com", exception: true, out: File::NULL)
      system("git", "-C", seeder, "config", "user.name", "Test", exception: true, out: File::NULL)
      dir
    end
  end

  # Push a commit to a bare remote from a new seeder clone.
  # Used in GB3 tests to simulate the remote gaining its first commit(s)
  # after an initially empty clone is already set up.
  def push_first_commit_to_bare(bare, content: "hello\n", filename: "README.md", message: "first commit")
    Dir.mktmpdir("repo-tender-seeder-") do |parent|
      fixture = File.join(parent, "repo")
      FileUtils.cp_r(TestHelpers.committed_seeder_template, fixture)
      seeder = File.join(fixture, "seeder")
      in_async do
        Shell.run("git", "push", "-q", bare, "trunk", chdir: seeder)
      end
    end
  end
end
