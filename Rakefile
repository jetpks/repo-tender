# frozen_string_literal: true

require "fileutils"
require "rake/testtask"

GEMSPEC = Gem::Specification.load("repo-tender.gemspec")
GEM_FILE = File.join("pkg", "#{GEMSPEC.full_name}.gem")

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.libs << "lib"
  task.pattern = "test/**/*_test.rb"
  task.warning = false
end

def sh_unbundled(*command)
  if defined?(Bundler)
    Bundler.with_unbundled_env { sh(*command) }
  else
    sh(*command)
  end
end

desc "Build #{GEM_FILE}"
task :build do
  FileUtils.mkdir_p("pkg")
  FileUtils.rm_f(GEM_FILE)
  sh_unbundled "gem", "build", "repo-tender.gemspec", "--output", GEM_FILE
end

desc "Install #{GEM_FILE} into the current Ruby user gem home"
task install: :build do
  install_args = ENV.fetch("INSTALL_ARGS", "--user-install --no-document").split
  sh_unbundled "gem", "install", *install_args, GEM_FILE
end

desc "Run mutation testing on RepoTender::Cloner"
task :mutant do
  sh "bundle", "exec", "mutant", "run", "--", "RepoTender::Cloner"
end

task default: :test
