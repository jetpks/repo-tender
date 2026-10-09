# frozen_string_literal: true

require "test_helper"
require "repo_tender/cloner"

class ClonerTest < Minitest::Test
  cover RepoTender::Cloner
  include TestHelpers

  def setup
    @orig_dir = Dir.pwd
    @cwd_tmp = Dir.mktmpdir("cloner-cwd-")
    Dir.chdir(@cwd_tmp)
  end

  def teardown
    Dir.chdir(@orig_dir)
    FileUtils.remove_entry(@cwd_tmp)
  end

  # ---- GB1: happy path COW copy ----

  def test_bare_name_resolves_and_copies
    Dir.mktmpdir("cloner-test-") do |base|
      seed_repo(base, "github.com", "owner", "myrepo", files: {"README.md" => "hello"})
      Dir.mktmpdir("cloner-into-") do |into|
        cloner = RepoTender::Cloner.new(base_dir: base)
        result = cloner.call(name: "myrepo", into: into)
        assert result.success?, "expected Success, got #{result.inspect}"
        dest = File.join(into, "myrepo")
        assert File.directory?(dest), "dest dir should exist"
        assert_equal "hello", File.read(File.join(dest, "README.md"))
        assert_equal "hello", File.read(File.join(base, "github.com", "owner", "myrepo", "README.md")),
          "source must be unchanged"
      end
    end
  end

  def test_returns_success_with_dest_path
    Dir.mktmpdir("cloner-test-") do |base|
      seed_repo(base, "github.com", "owner", "myrepo")
      Dir.mktmpdir("cloner-into-") do |into|
        cloner = RepoTender::Cloner.new(base_dir: base)
        result = cloner.call(name: "myrepo", into: into)
        assert result.success?
        assert_equal File.join(into, "myrepo"), result.success
      end
    end
  end

  # ---- GB2: name resolution ----

  def test_bare_name_resolves_to_single_match
    Dir.mktmpdir("cloner-test-") do |base|
      seed_repo(base, "github.com", "acme", "widget")
      Dir.mktmpdir do |into|
        result = RepoTender::Cloner.new(base_dir: base).call(name: "widget", into: into)
        assert result.success?, result.inspect
      end
    end
  end

  def test_owner_slash_name_resolves
    Dir.mktmpdir("cloner-test-") do |base|
      seed_repo(base, "github.com", "acme", "widget")
      Dir.mktmpdir do |into|
        result = RepoTender::Cloner.new(base_dir: base).call(name: "acme/widget", into: into)
        assert result.success?, result.inspect
      end
    end
  end

  def test_host_slash_owner_slash_name_resolves
    Dir.mktmpdir("cloner-test-") do |base|
      seed_repo(base, "github.com", "acme", "widget")
      Dir.mktmpdir do |into|
        result = RepoTender::Cloner.new(base_dir: base).call(name: "github.com/acme/widget", into: into)
        assert result.success?, result.inspect
      end
    end
  end

  def test_unknown_name_returns_failure_copies_nothing
    Dir.mktmpdir("cloner-test-") do |base|
      seed_repo(base, "github.com", "acme", "widget")
      Dir.mktmpdir do |into|
        result = RepoTender::Cloner.new(base_dir: base).call(name: "nosuchrepo", into: into)
        assert result.failure?, "expected Failure"
        assert_includes result.failure, "not found"
        assert_empty Dir.entries(into).reject { |e| [".", ".."].include?(e) }, "nothing should be copied"
      end
    end
  end

  def test_ambiguous_bare_name_returns_failure_lists_candidates
    Dir.mktmpdir("cloner-test-") do |base|
      seed_repo(base, "github.com", "org1", "shared")
      seed_repo(base, "github.com", "org2", "shared")
      Dir.mktmpdir do |into|
        result = RepoTender::Cloner.new(base_dir: base).call(name: "shared", into: into)
        assert result.failure?
        assert_includes result.failure, "ambiguous"
        assert_includes result.failure, "org1/shared"
        assert_includes result.failure, "org2/shared"
        assert_empty Dir.entries(into).reject { |e| [".", ".."].include?(e) }, "nothing copied on ambiguity"
      end
    end
  end

  def test_fully_qualified_disambiguates_ambiguous_bare_name
    Dir.mktmpdir("cloner-test-") do |base|
      seed_repo(base, "github.com", "org1", "shared")
      seed_repo(base, "github.com", "org2", "shared")
      Dir.mktmpdir do |into|
        result = RepoTender::Cloner.new(base_dir: base).call(name: "org1/shared", into: into)
        assert result.success?, result.inspect
        assert File.directory?(File.join(into, "shared"))
      end
    end
  end

  # ---- GB3: no-clobber (no-data-loss, copy target) ----

  def test_existing_dest_returns_failure_unchanged
    Dir.mktmpdir("cloner-test-") do |base|
      seed_repo(base, "github.com", "owner", "myrepo", files: {"new.txt" => "new content"})
      Dir.mktmpdir("cloner-into-") do |into|
        # Pre-populate the destination with a sentinel file.
        dest = File.join(into, "myrepo")
        FileUtils.mkdir_p(dest)
        sentinel = File.join(dest, "sentinel.txt")
        File.write(sentinel, "do not overwrite")

        result = RepoTender::Cloner.new(base_dir: base).call(name: "myrepo", into: into)
        assert result.failure?, "expected Failure when dest exists"
        assert_includes result.failure, "already exists"

        # Sentinel is byte-for-byte unchanged.
        assert_equal "do not overwrite", File.read(sentinel),
          "sentinel must be untouched after rejected clone"
        refute File.exist?(File.join(dest, "new.txt")),
          "source file must not appear in pre-existing dest"
      end
    end
  end

  private

  def seed_repo(base, host, owner, name, files: {"SEED" => "seed"})
    path = File.join(base, host, owner, name)
    FileUtils.mkdir_p(path)
    files.each { |fname, content| File.write(File.join(path, fname), content) }
    path
  end
end
