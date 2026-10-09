# frozen_string_literal: true

require "test_helper"
require "repo_tender/nav"

class NavTest < Minitest::Test
  Nav = RepoTender::Nav

  # ---- subsequence matching ----

  def test_spaarc_matches_space_architect
    assert match_positions("spaarc", "jetpks/space-architect"),
      "spaarc must be a subsequence of jetpks/space-architect (matching owner/name only)"
  end

  def test_jetspact_matches_space_architect
    assert match_positions("jetspact", "jetpks/space-architect"),
      "jetspact must be a subsequence of jetpks/space-architect"
  end

  def test_ksacch_matches_space_architect
    assert match_positions("ksacch", "jetpks/space-architect"),
      "ksacch must be a subsequence of jetpks/space-architect"
  end

  def test_non_subsequence_does_not_match
    refute match_positions("zzx", "jetpks/space-architect"),
      "zzx must not match jetpks/space-architect"
  end

  def test_non_subsequence_wrong_order
    refute match_positions("ca", "abc"),
      "ca must not match abc (wrong order)"
  end

  def test_case_insensitive
    assert match_positions("SPACE", "owner/space-repo")
    assert match_positions("Space", "owner/space-repo")
  end

  # ---- host excluded from match target ----

  def test_host_excluded_from_match
    # query "github" would match if host were included; it must NOT match owner/name
    refute match_positions("github", "owner/myrepo"),
      "host must be excluded from the match target"
  end

  def test_host_chars_in_owner_name_still_match
    # "gith" as a subsequence of "github/myrepo" → would only match if host is excluded
    # but "gith" IS a subsequence of "github/myrepo" as owner/name? No — owner is "github", name is "myrepo"
    # target = "github/myrepo" — host is excluded, owner=github, name=myrepo
    # So target = "github/myrepo". "gith" → g(0)i(1)t(2)h(3) → matches (owner starts with "github")
    # This is fine — the host exclusion means we don't add another "github.com/" prefix.
    assert match_positions("gith", "github/myrepo")
  end

  # ---- ranking: fzf-style with deterministic total order ----

  def test_contiguous_match_outranks_scattered
    entries = [
      {host: "github.com", owner: "owner", name: "bc-extra", target: "owner/bc-extra", path: "/s/g/owner/bc-extra"},
      {host: "github.com", owner: "owner", name: "bxc-extra", target: "owner/bxc-extra", path: "/s/g/owner/bxc-extra"}
    ]
    # query "bc":
    # "owner/bc-extra"  → b at 6 (after '/'), c at 7 — contiguous pair. Score higher.
    # "owner/bxc-extra" → b at 6 (after '/'), c at 8 — no contiguous pair. Score lower.
    ranked = Nav.rank(entries, "bc")
    assert_equal "owner/bc-extra", ranked.first[:target],
      "contiguous match must outrank non-contiguous match"
  end

  def test_word_boundary_bonus
    entries = [
      {host: "github.com", owner: "aaa", name: "bbbfoo", target: "aaa/bbbfoo", path: "/s/g/aaa/bbbfoo"},
      {host: "github.com", owner: "foo", name: "bar", target: "foo/bar", path: "/s/g/foo/bar"}
    ]
    # query "f": in "aaa/bbbfoo" → f is at index 7 (mid-word, no boundary)
    # in "foo/bar" → f is at index 0 (start of string, word boundary!)
    ranked = Nav.rank(entries, "f")
    assert_equal "foo/bar", ranked.first[:target],
      "word-boundary match must outrank mid-word match"
  end

  def test_ranking_is_deterministic_with_total_tiebreak
    # Two entries with IDENTICAL match positions and score — tie broken by target asc.
    # Using same name suffix so "qrs" lands at the same index in both targets.
    entries = [
      {host: "github.com", owner: "zzz", name: "qrs", target: "zzz/qrs", path: "/s/g/zzz/qrs"},
      {host: "github.com", owner: "aaa", name: "qrs", target: "aaa/qrs", path: "/s/g/aaa/qrs"}
    ]
    ranked = Nav.rank(entries, "qrs")
    # "aaa/qrs" and "zzz/qrs" both match at positions [4,5,6] → identical score.
    # Tie-break: target asc → "aaa/qrs" < "zzz/qrs"
    assert_equal "aaa/qrs", ranked.first[:target]
    assert_equal "zzz/qrs", ranked.last[:target]
  end

  def test_host_tiebreak_when_target_identical
    entries = [
      {host: "gitlab.com", owner: "org", name: "repo", target: "org/repo", path: "/s/gl/org/repo"},
      {host: "github.com", owner: "org", name: "repo", target: "org/repo", path: "/s/gh/org/repo"}
    ]
    ranked = Nav.rank(entries, "or")
    # Same target → tiebreak by host asc: "github.com" < "gitlab.com"
    assert_equal "github.com", ranked.first[:host]
    assert_equal "gitlab.com", ranked.last[:host]
  end

  def test_multiple_targets_ranked_best_first
    entries = [
      {host: "github.com", owner: "jetpks", name: "space-architect", target: "jetpks/space-architect", path: "/s/g/jetpks/space-architect"},
      {host: "github.com", owner: "owner", name: "src-zz-aarc", target: "owner/src-zz-aarc", path: "/s/g/owner/src-zz-aarc"}
    ]
    # query "spaarc":
    # "jetpks/space-architect": s at 7 (word boundary after '/'), p,a consecutive — high score
    # "owner/src-zz-aarc": s at 6 (word boundary after '/'), then r,c,a,a,r,c scattered
    ranked = Nav.rank(entries, "spaarc")
    assert_equal "jetpks/space-architect", ranked.first[:target]
  end

  def test_no_matches_returns_empty
    entries = [{host: "github.com", owner: "foo", name: "bar", target: "foo/bar", path: "/x"}]
    assert_empty Nav.rank(entries, "zzz")
  end

  # ---- filesystem scan (uses a temp dir) ----

  def test_scan_finds_depth3_dirs
    Dir.mktmpdir do |base|
      FileUtils.mkdir_p(File.join(base, "github.com", "alice", "myrepo"))
      FileUtils.mkdir_p(File.join(base, "github.com", "bob", "otherrepo"))
      # Not depth-3: should be ignored
      FileUtils.mkdir_p(File.join(base, "github.com", "alice"))

      entries = Nav.scan(base)
      targets = entries.map { |e| e[:target] }.sort
      assert_equal ["alice/myrepo", "bob/otherrepo"], targets
    end
  end

  def test_scan_excludes_files
    Dir.mktmpdir do |base|
      FileUtils.mkdir_p(File.join(base, "github.com", "alice", "myrepo"))
      File.write(File.join(base, "github.com", "alice", "notarepo"), "file")

      entries = Nav.scan(base)
      assert_equal 1, entries.length
      assert_equal "alice/myrepo", entries.first[:target]
    end
  end

  def test_scan_populates_absolute_path
    Dir.mktmpdir do |base|
      path = File.join(base, "github.com", "alice", "myrepo")
      FileUtils.mkdir_p(path)
      entries = Nav.scan(base)
      assert_equal path, entries.first[:path]
    end
  end

  private

  def match_positions(query, target)
    Nav.match_positions(query, target)
  end
end
