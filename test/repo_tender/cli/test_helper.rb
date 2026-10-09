# frozen_string_literal: true

require "stringio"
require "open3"
require "test_helper"

module CLITestHelpers
  def with_cli_env
    with_temp_home do |env, home|
      Thread.current[:repo_tender_cli_env] = env
      yield(env, home)
    end
  ensure
    Thread.current[:repo_tender_cli_env] = nil
  end

  def invoke_command(command_class, **kwargs)
    RepoTender::CLI.last_outcome # drain
    Thread.current[:repo_tender_cli_outcome] = nil
    out = StringIO.new
    err = StringIO.new
    cmd = command_class.new
    cmd.instance_variable_set(:@out, out)
    cmd.instance_variable_set(:@err, err)
    cmd.call(**kwargs)
    [out, err]
  end

  def run_cli_subprocess(env:, **opts)
    args = opts.fetch(:args, [])
    ruby = opts.fetch(:ruby, "ruby")
    Open3.capture3(env, ruby, "-Ilib", File.expand_path("../../../exe/repo-tender", __dir__), *args)
  end
end
