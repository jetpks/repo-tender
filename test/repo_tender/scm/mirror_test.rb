# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

# SCM::Mirror against real temp git repos + local bare remotes (house
# style — no network anywhere). Clone → bare + mirror-configured +
# identical refs; update → convergence + pruning; last_fetch_at on the
# bare FETCH_HEAD layout; the mirror? probe.
class SCMMirrorTest < Minitest::Test
  include TestHelpers

  Mirror = RepoTender::SCM::Mirror

  def refs_of(path)
    result = Shell.run("git", "for-each-ref", "--format=%(refname)", chdir: path)
    assert result.success?, "for-each-ref failed in #{path}: #{result.failure.inspect}"
    result.success.lines.map(&:strip).reject(&:empty?).sort
  end

  # A seeded bare remote carrying more than one ref (trunk + a tag +
  # a feature branch) so ref-set equality is meaningful. Yields the
  # bare, a work clone, and (for the update test) nothing else.
  def with_rich_bare
    Dir.mktmpdir("rt-mirror-bare-") do |dir|
      fixture = File.join(dir, "fixture")
      FileUtils.cp_r(TestHelpers.seeded_trunk_template, fixture)
      bare = File.join(fixture, "bare.git")
      work = File.join(fixture, "clone")
      in_async do
        Shell.run("git", "remote", "set-url", "origin", bare, chdir: work)
        Shell.run("git", "tag", "v1", chdir: work)
        Shell.run("git", "push", "-q", "origin", "v1", chdir: work)
        Shell.run("git", "switch", "-c", "feature", chdir: work)
        Shell.run("git", "push", "-q", "origin", "feature", chdir: work)
        yield(bare, work, dir)
      end
    end
  end

  # ---- clone ----

  def test_clone_makes_bare_mirror_configured_with_identical_refs
    with_rich_bare do |bare, _work, dir|
      mirror = Mirror.new
      # Nested dest exercises the mkdir_p-parent parity with SCM::Git#clone.
      dest = File.join(dir, "nested", "parent", "mirror.git")
      refute File.exist?(File.dirname(dest)), "precondition: parent dir absent"

      result = mirror.clone(bare, dest)
      assert result.success?, result.failure.inspect
      assert_equal dest, result.success

      is_bare = Shell.run("git", "rev-parse", "--is-bare-repository", chdir: dest).success.strip
      assert_equal "true", is_bare, "mirror clone must be bare"

      mirror_config = Shell.run("git", "config", "--get", "remote.origin.mirror", chdir: dest).success.strip
      assert_equal "true", mirror_config, "remote.origin.mirror must be set"

      assert_equal refs_of(bare), refs_of(dest),
        "mirror refs must be identical to origin's (all refs, all objects)"
      refute File.exist?(File.join(dest, "README.md")),
        "a mirror checks nothing out (no working tree)"
    end
  end

  def test_clone_failure_against_nonexistent_local_url_carries_stderr
    Dir.mktmpdir("rt-mirror-bad-") do |dir|
      bad = File.join(dir, "no-such.git")
      dest = File.join(dir, "dest.git")
      mirror = Mirror.new
      in_async do
        result = mirror.clone(bad, dest)
        assert result.failure?, "clone of a nonexistent URL must fail"
        failure = result.failure
        assert_equal bad, failure[:url]
        assert_equal dest, failure[:dest]
        refute failure[:stderr].to_s.empty?, "real git stderr must ride the Failure"
        assert_includes failure[:stderr].downcase, "does not exist",
          "expected git's nonexistent-repository diagnostic, got: #{failure[:stderr].inspect}"
        refute File.exist?(dest)
      end
    end
  end

  # ---- update + last_fetch_at ----

  def test_last_fetch_at_nil_on_fresh_clone_then_time_after_update
    with_rich_bare do |bare, _work, dir|
      mirror = Mirror.new
      dest = File.join(dir, "mirror.git")
      clone_result = mirror.clone(bare, dest)
      assert clone_result.success?, clone_result.failure.inspect

      fresh = mirror.last_fetch_at(dest)
      assert fresh.success?
      assert_nil fresh.success, "FETCH_HEAD does not exist after a fresh clone — freshness reads as stale"

      marker = Time.at(Time.now.to_i)
      update_result = mirror.update(dest)
      assert update_result.success?, update_result.failure.inspect
      assert_equal dest, update_result.success

      fetched = mirror.last_fetch_at(dest)
      assert fetched.success?
      assert_kind_of Time, fetched.success, "remote update creates FETCH_HEAD"
      assert_operator fetched.success, :>=, marker
    end
  end

  def test_update_converges_refs_and_prunes_deleted_ones
    with_rich_bare do |bare, work, dir|
      mirror = Mirror.new
      dest = File.join(dir, "mirror.git")
      clone_result = mirror.clone(bare, dest)
      assert clone_result.success?, clone_result.failure.inspect
      assert_includes refs_of(dest), "refs/heads/feature", "precondition: feature present at clone time"

      # Origin gains `topic` and loses `feature`…
      Shell.run("git", "switch", "-c", "topic", chdir: work)
      Shell.run("git", "push", "-q", "origin", "topic", chdir: work)
      Shell.run("git", "push", "-q", "origin", "--delete", "feature", chdir: work)

      update_result = mirror.update(dest)
      assert update_result.success?, update_result.failure.inspect

      assert_includes refs_of(dest), "refs/heads/topic", "new origin branch must appear in the mirror"
      refute_includes refs_of(dest), "refs/heads/feature", "deleted origin branch must be pruned"
      assert_equal refs_of(bare), refs_of(dest), "mirror must converge to origin's ref set"
    end
  end

  def test_update_failure_on_a_non_repo_reports_reason_and_stderr
    Dir.mktmpdir("rt-mirror-norepo-") do |dir|
      mirror = Mirror.new
      in_async do
        result = mirror.update(dir)
        assert result.failure?, "remote update outside a repo must fail"
        failure = result.failure
        assert_equal dir, failure[:path]
        refute failure[:reason].to_s.empty?
        refute failure[:stderr].to_s.empty?
      end
    end
  end

  # ---- mirror? ----

  def test_mirror_probe_true_only_on_a_real_mirror
    with_rich_bare do |bare, _work, dir|
      mirror = Mirror.new
      dest = File.join(dir, "mirror.git")
      clone_result = mirror.clone(bare, dest)
      assert clone_result.success?, clone_result.failure.inspect

      probe = mirror.mirror?(dest)
      assert probe.success?, probe.failure.inspect
      assert_equal true, probe.success, "clone --mirror dest must probe true"

      # Non-bare working clone: bare probe answers false.
      working = File.join(dir, "working")
      Shell.run("git", "clone", "-q", bare, working)
      non_bare = mirror.mirror?(working)
      assert non_bare.success?
      assert_equal false, non_bare.success, "a working clone is not a mirror"

      # Bare but not mirror-configured.
      plain_bare = File.join(dir, "plain.git")
      Shell.run("git", "init", "-q", "--bare", plain_bare)
      bare_no_mirror = mirror.mirror?(plain_bare)
      assert bare_no_mirror.success?
      assert_equal false, bare_no_mirror.success, "git init --bare without remote.origin.mirror is not a mirror"

      # Missing path.
      missing = mirror.mirror?(File.join(dir, "does-not-exist"))
      assert missing.success?
      assert_equal false, missing.success, "a missing path probes false, not Failure"

      # Existing directory that is not a git repo at all.
      plain_dir = File.join(dir, "plain-dir")
      FileUtils.mkdir_p(plain_dir)
      not_a_repo = mirror.mirror?(plain_dir)
      assert not_a_repo.success?
      assert_equal false, not_a_repo.success, "a non-repo directory probes false"
    end
  end
end
