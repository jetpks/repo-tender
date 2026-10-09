# frozen_string_literal: true

require "test_helper"
require "repo_tender/migration"

class MigrationTest < Minitest::Test
  include TestHelpers

  Migration = RepoTender::Migration
  OLD_LABEL = Migration::OLD_LABEL
  OLD_APP_NAME = Migration::OLD_APP_NAME

  # Build a Paths object under a temp home.
  def with_migration_paths
    with_temp_home do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      yield(env, paths)
    end
  end

  # ---- AC#4(a): existing old dir moves to new dir with contents byte-intact ----

  def test_migrates_config_and_state_dirs
    with_migration_paths do |env, paths|
      old_config = File.join(paths.config_home, OLD_APP_NAME)
      old_state = File.join(paths.state_home, OLD_APP_NAME)
      old_logs = File.join(old_state, "logs")

      FileUtils.mkdir_p(old_config)
      FileUtils.mkdir_p(old_logs)
      File.write(File.join(old_config, "config.yaml"), "base_dir: /some/path\n")
      File.write(File.join(old_state, "state.yaml"), "repos: {}\n")
      File.write(File.join(old_logs, "test.log"), "log content\n")

      err = StringIO.new
      Migration.run(paths: paths, err: err)

      refute File.exist?(old_config), "old config dir should have been removed"
      refute File.exist?(old_state), "old state dir should have been removed"

      assert File.exist?(paths.config_dir), "new config dir should exist"
      assert File.exist?(paths.state_dir), "new state dir should exist"

      assert_equal "base_dir: /some/path\n", File.read(File.join(paths.config_dir, "config.yaml"))
      assert_equal "repos: {}\n", File.read(File.join(paths.state_dir, "state.yaml"))
      assert_equal "log content\n", File.read(File.join(paths.state_dir, "logs", "test.log"))

      assert_includes err.string, "migrated"
    end
  end

  # ---- AC#4(b): second run is a no-op (idempotent) ----

  def test_migration_is_idempotent
    with_migration_paths do |env, paths|
      old_config = File.join(paths.config_home, OLD_APP_NAME)
      FileUtils.mkdir_p(old_config)
      File.write(File.join(old_config, "config.yaml"), "base_dir: /x\n")

      err1 = StringIO.new
      Migration.run(paths: paths, err: err1)
      assert_includes err1.string, "migrated"

      # After migration, old dir is gone and new dir exists.
      refute File.exist?(old_config)
      assert File.exist?(paths.config_dir)

      err2 = StringIO.new
      Migration.run(paths: paths, err: err2)
      refute_includes err2.string, "migrated", "second run should not print migration notice"

      # Contents unchanged.
      assert_equal "base_dir: /x\n", File.read(File.join(paths.config_dir, "config.yaml"))
    end
  end

  # ---- AC#4(c): pre-existing new dir is NOT clobbered ----

  def test_no_clobber_when_both_dirs_exist
    with_migration_paths do |env, paths|
      old_config = File.join(paths.config_home, OLD_APP_NAME)
      FileUtils.mkdir_p(old_config)
      File.write(File.join(old_config, "config.yaml"), "base_dir: /old\n")

      FileUtils.mkdir_p(paths.config_dir)
      File.write(File.join(paths.config_dir, "config.yaml"), "base_dir: /new\n")

      err = StringIO.new
      Migration.run(paths: paths, err: err)

      # Both dirs still exist — no move, no clobber.
      assert File.exist?(old_config), "old config dir must be untouched"
      assert_equal "base_dir: /old\n", File.read(File.join(old_config, "config.yaml"))
      assert_equal "base_dir: /new\n", File.read(File.join(paths.config_dir, "config.yaml"))

      refute_includes err.string, "migrated"
    end
  end

  # ---- neither dir exists: silent no-op ----

  def test_no_op_when_neither_dir_exists
    with_migration_paths do |_env, paths|
      refute File.exist?(File.join(paths.config_home, OLD_APP_NAME))
      refute File.exist?(paths.config_dir)

      err = StringIO.new
      Migration.run(paths: paths, err: err)

      refute_includes err.string, "migrated"
    end
  end

  # ---- old plist present: emits advisory ----

  def test_warns_when_old_label_plist_present
    with_migration_paths do |env, paths|
      old_pp = File.join(paths.launch_agents_dir, "#{OLD_LABEL}.plist")
      FileUtils.mkdir_p(File.dirname(old_pp))
      File.write(old_pp, "<?xml version=\"1.0\"?><plist/>")

      err = StringIO.new
      Migration.run(paths: paths, err: err)

      assert_includes err.string, OLD_LABEL
      assert_includes err.string, "repo-tender daemon install"
    end
  end

  # ---- no old plist: no advisory ----

  def test_no_warning_when_old_plist_absent
    with_migration_paths do |_env, paths|
      err = StringIO.new
      Migration.run(paths: paths, err: err)

      refute_includes err.string, OLD_LABEL
    end
  end
end
