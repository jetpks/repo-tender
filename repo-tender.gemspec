# frozen_string_literal: true

require_relative "lib/repo_tender/version"

Gem::Specification.new do |spec|
  spec.name = "repo-tender"
  spec.version = RepoTender::VERSION
  spec.authors = ["Eric Jacobs"]
  spec.email = ["eric@ebj.dev"]

  spec.summary = "Keep your local git clones forever evergreen 🌲 — clean, on default branch, and freshly fetched!"
  spec.description = "A dry-cli binary plus a periodic launchd sync sweep that keeps every tracked repo " \
    "(and whole GitHub orgs!) clean, on its default branch, and up to date — so anything downstream can " \
    "clone from local disk instantly. macOS-only, GitHub-only (behind decoupled SCM/forge interfaces). " \
    "Never destroys your work: dirty or diverged repos are reported, never touched. ヽ(•‿•)ノ✨"
  spec.homepage = "https://github.com/jetpks/repo-tender"
  spec.license = "MIT"
  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/jetpks/repo-tender/issues",
    "homepage_uri" => "https://github.com/jetpks/repo-tender",
    "source_code_uri" => "https://github.com/jetpks/repo-tender"
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "bin/**/*",
    "README.md",
    "LICENSE.txt",
    "repo-tender.gemspec"
  ]
  spec.bindir = "bin"
  spec.executables = ["repo-tender"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.3"

  spec.add_dependency "async", "~> 2.39"
  spec.add_dependency "dry-cli", "~> 1.4"
  spec.add_dependency "dry-monads", "~> 1.10"
  spec.add_dependency "dry-schema", "~> 1.16"
  spec.add_dependency "dry-struct", "~> 1.8"
  spec.add_dependency "dry-types", "~> 1.9"
  spec.add_dependency "dry-validation", "~> 1.11"
  spec.add_dependency "xdg", "~> 10.2"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "tty-cursor", "~> 0.7"
end
