# frozen_string_literal: true

require "repo_tender/version"

# repo-tender — keep local git clones evergreen.
# (clean · on the remote's default branch · fetched within refresh_interval)
#
# Slice 1 surface: Paths, Shell, Config::{Model,Contract,Store},
# State::Store, SCM::{Client,Git,Status}, Forge::{Client,GitHub}.
# Later slices build sync orchestration, CLI, and launchd on top.

module RepoTender
end

require "repo_tender/paths"
require "repo_tender/shell"
require "repo_tender/config/model"
require "repo_tender/config/contract"
require "repo_tender/config/store"
require "repo_tender/state/store"
require "repo_tender/state/lock"
require "repo_tender/scm/client"
require "repo_tender/scm/status"
require "repo_tender/scm/git"
require "repo_tender/forge/client"
require "repo_tender/forge/github"
require "repo_tender/sync/repo_plan"
require "repo_tender/sync/report"
require "repo_tender/sync/engine"
require "repo_tender/config/duration"
require "repo_tender/log_rotator"
require "repo_tender/launchd/plist"
require "repo_tender/launchd/agent"
require "repo_tender/ui/reporter"
require "repo_tender/ui/mode"
require "repo_tender/ui/plain_reporter"
require "repo_tender/ui/json_reporter"
require "repo_tender/cli"
