# frozen_string_literal: true

require "async"
require "dry/monads"
require "repo_tender/shell"

module RepoTender
  # Resolution + COW-copy boundary for `clone`. Returns Result; no
  # side effects on Failure. Injected shell seam defaults to ShellRunner
  # (wraps Shell.run in Sync{} so the Fiber-scheduler requirement is met
  # from a plain synchronous CLI command — same pattern as Launchd::Agent).
  class Cloner
    include Dry::Monads[:result]

    class ShellRunner
      def run(*argv)
        Sync { RepoTender::Shell.run(*argv) }
      end
    end

    def initialize(base_dir:, shell: ShellRunner.new)
      @base_dir = File.expand_path(base_dir)
      @shell = shell
    end

    # Resolve `name` against `base_dir` and copy to `into/<leaf>`.
    # Returns Success(dest_path) or Failure(message).
    def call(name:, into: ".")
      result = resolve(name)
      return result if result.failure?
      copy(result.success, into)
    end

    private

    def resolve(name)
      parts = name.split("/")
      case parts.length
      when 1
        # paths:exempt - layout intent (checkout resolution by depth); repo_tender is deliberately independent of space_core and must not require it
        candidates = Dir.glob(File.join(@base_dir, "*", "*", name))
        case candidates.length
        when 0 then Failure("#{name.inspect} not found under base_dir #{@base_dir}")
        when 1 then Success(candidates.first)
        else ambiguous(name, candidates, "owner/name or host/owner/name")
        end
      when 2
        owner, repo_name = parts
        # paths:exempt - layout intent (checkout resolution by depth); repo_tender is deliberately independent of space_core and must not require it
        candidates = Dir.glob(File.join(@base_dir, "*", owner, repo_name))
        case candidates.length
        when 0 then Failure("#{name.inspect} not found under base_dir #{@base_dir}")
        when 1 then Success(candidates.first)
        else ambiguous(name, candidates, "host/owner/name")
        end
      when 3
        path = File.join(@base_dir, *parts)
        File.directory?(path) ? Success(path) : Failure("#{name.inspect} not found under base_dir #{@base_dir}")
      else
        Failure("invalid repo reference: #{name.inspect}")
      end
    end

    def ambiguous(name, candidates, hint)
      list = candidates.map { |c| "  #{c.delete_prefix("#{@base_dir}/")}" }.join("\n")
      Failure("ambiguous name #{name.inspect}; qualify with #{hint}:\n#{list}")
    end

    def copy(src, into)
      leaf = File.basename(src)
      dest = File.join(File.expand_path(into), leaf)
      return Failure("destination already exists: #{dest}") if File.exist?(dest)
      result = @shell.run("cp", "-Rc", src, dest)
      result.success? ? Success(dest) : result
    end
  end
end
