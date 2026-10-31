# frozen_string_literal: true

require "test_helper"

# Forge::GitHubToken driven through a StubHttp collaborator at the
# Forge::HTTP seam (the StubShell pattern from github_test.rb: the
# double answers URL → Response; the client under test is real).
# Bodies come from recorded-style fixtures; transport metadata
# (status, Link header) is authored here. No network.
class ForgeGitHubTokenTest < Minitest::Test
  GitHubToken = RepoTender::Forge::GitHubToken
  Response = RepoTender::Forge::HTTP::Response
  OrgRef = RepoTender::Config::OrgRef

  FIXTURES = File.expand_path("../../fixtures/github_api", __dir__)
  API = "https://api.github.com"
  TOKEN = "ghp_testtoken123"
  NEXT_LINK = "<#{API}/orgs/cli/repos?per_page=100&page=2>; rel=\"next\", " \
    "<#{API}/orgs/cli/repos?per_page=100&page=2>; rel=\"last\""

  # Answers URL → Response (or a Result for transport failures);
  # records every request's URL + headers.
  class StubHttp
    attr_reader :requests

    def initialize(mapping = {})
      @mapping = mapping
      @requests = []
    end

    def get(url, headers: {})
      @requests << {url: url, headers: headers}
      entry = @mapping.fetch(url) { raise "StubHttp: unhandled GET #{url}" }
      entry.is_a?(Dry::Monads::Result) ? entry : Dry::Monads::Success(entry)
    end
  end

  def fixture_body(name) = File.read(File.join(FIXTURES, name))

  def repos_url(page, org: "cli")
    "#{API}/orgs/#{org}/repos?per_page=100&page=#{page}"
  end

  def user_response(status: 200)
    Dry::Monads::Success(Response.new(
      status: status,
      headers: {},
      body: fixture_body("user.json")
    ))
  end

  def page_response(fixture, link: nil)
    headers = {}
    headers["Link"] = link if link
    Dry::Monads::Success(Response.new(
      status: 200,
      headers: headers,
      body: fixture_body(fixture)
    ))
  end

  # ---- Constructor ----

  def test_token_is_required
    assert_raises(ArgumentError) { GitHubToken.new(token: nil) }
    assert_raises(ArgumentError) { GitHubToken.new(token: "") }
  end

  # ---- check_authenticated ----

  def test_check_authenticated_success_on_200_sends_bearer_and_github_accept
    http = StubHttp.new("#{API}/user" => user_response)
    result = GitHubToken.new(token: TOKEN, http: http).check_authenticated
    assert result.success?, result.failure.inspect
    assert_equal :authenticated, result.success

    assert_equal 1, http.requests.size, "check_authenticated is a single probe"
    sent = http.requests.first
    assert_equal "#{API}/user", sent[:url]
    assert_equal "Bearer #{TOKEN}", sent[:headers]["Authorization"]
    assert_equal "application/vnd.github+json", sent[:headers]["Accept"]
  end

  def test_check_authenticated_failure_on_401
    http = StubHttp.new("#{API}/user" => user_response(status: 401))
    result = GitHubToken.new(token: "ghp_wrong", http: http).check_authenticated
    assert result.failure?
    assert_equal "github token rejected (HTTP 401); check the token and scopes",
      result.failure[:reason]
  end

  def test_check_authenticated_failure_on_403
    http = StubHttp.new("#{API}/user" => user_response(status: 403))
    result = GitHubToken.new(token: "ghp_wrong", http: http).check_authenticated
    assert result.failure?
    assert_equal "github token rejected (HTTP 403); check the token and scopes",
      result.failure[:reason]
  end

  def test_check_authenticated_failure_on_other_status
    http = StubHttp.new("#{API}/user" => user_response(status: 503))
    result = GitHubToken.new(token: TOKEN, http: http).check_authenticated
    assert result.failure?
    assert_equal "HTTP 503 from /user", result.failure[:reason]
  end

  def test_check_authenticated_maps_transport_failure_into_reason
    transport = Dry::Monads::Failure({url: "#{API}/user", error: "Errno::ECONNREFUSED: Connection refused"})
    http = StubHttp.new("#{API}/user" => transport)
    result = GitHubToken.new(token: TOKEN, http: http).check_authenticated
    assert result.failure?
    assert_equal "Errno::ECONNREFUSED: Connection refused", result.failure[:reason]
  end

  # ---- list_org: pagination ----

  def test_list_org_walks_two_pages_following_link_rel_next
    http = StubHttp.new(
      repos_url(1) => page_response("org_repos_p1.json", link: NEXT_LINK),
      repos_url(2) => page_response("org_repos_p2.json")
    )
    result = GitHubToken.new(token: TOKEN, http: http)
      .list_org(OrgRef.new(name: "cli", include_archived: true, include_forks: true))
    assert result.success?, result.failure.inspect
    names = result.success.map(&:name)
    assert_equal %w[browser cli go-gh kit octocat], names.sort

    assert_equal [repos_url(1), repos_url(2)], http.requests.map { |r| r[:url] },
      "pagination must walk exactly page 1 → page 2"
    assert http.requests.all? { |r| r[:headers]["Authorization"] == "Bearer #{TOKEN}" },
      "every listing request carries the Bearer token"
  end

  def test_list_org_stops_after_one_page_without_next_link
    http = StubHttp.new(repos_url(1) => page_response("org_repos_p1.json"))
    result = GitHubToken.new(token: TOKEN, http: http)
      .list_org(OrgRef.new(name: "cli", include_archived: true, include_forks: true))
    assert result.success?
    assert_equal 3, result.success.length
    assert_equal 1, http.requests.size, "no rel=\"next\" → exactly one page fetched"
  end

  def test_list_org_stops_and_succeeds_at_ten_pages
    # Every page advertises rel="next"; the cap must stop-and-succeed
    # at 10 pages (LIST_LIMIT parity), keeping page 10's rows.
    mapping = (1..10).each_with_object({}) do |page, acc|
      body = "[{\"full_name\": \"cli/page#{page}\", \"fork\": false, \"archived\": false}]"
      acc[repos_url(page)] = Dry::Monads::Success(Response.new(
        status: 200,
        headers: {"Link" => "<#{repos_url(page + 1)}>; rel=\"next\""},
        body: body
      ))
    end
    http = StubHttp.new(mapping)
    result = GitHubToken.new(token: TOKEN, http: http)
      .list_org(OrgRef.new(name: "cli"))
    assert result.success?, result.failure.inspect
    assert_equal 10, result.success.length
    assert_equal 10, http.requests.size, "page 11 must never be fetched"
  end

  # ---- list_org: filters (authoritative client-side) ----

  def test_list_org_excludes_archived_and_forks_by_default
    http = StubHttp.new(
      repos_url(1) => page_response("org_repos_p1.json", link: NEXT_LINK),
      repos_url(2) => page_response("org_repos_p2.json")
    )
    result = GitHubToken.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "cli"))
    assert result.success?
    assert_equal %w[browser cli kit], result.success.map(&:name).sort
  end

  def test_list_org_includes_archived_when_flagged
    http = StubHttp.new(
      repos_url(1) => page_response("org_repos_p1.json", link: NEXT_LINK),
      repos_url(2) => page_response("org_repos_p2.json")
    )
    result = GitHubToken.new(token: TOKEN, http: http)
      .list_org(OrgRef.new(name: "cli", include_archived: true))
    assert result.success?
    names = result.success.map(&:name)
    assert_includes names, "go-gh"
    refute_includes names, "octocat"
  end

  def test_list_org_includes_forks_when_flagged
    http = StubHttp.new(
      repos_url(1) => page_response("org_repos_p1.json", link: NEXT_LINK),
      repos_url(2) => page_response("org_repos_p2.json")
    )
    result = GitHubToken.new(token: TOKEN, http: http)
      .list_org(OrgRef.new(name: "cli", include_forks: true))
    assert result.success?
    names = result.success.map(&:name)
    assert_includes names, "octocat"
    refute_includes names, "go-gh"
  end

  def test_list_org_builds_repo_refs_from_full_name
    http = StubHttp.new(repos_url(1) => page_response("org_repos_p1.json"))
    result = GitHubToken.new(token: TOKEN, http: http)
      .list_org(OrgRef.new(name: "cli", include_archived: true))
    assert result.success?
    cli = result.success.find { |r| r.name == "cli" }
    refute_nil cli
    assert_equal "cli", cli.owner
    assert_equal "github.com", cli.host, "host comes from the OrgRef"
  end

  # ---- list_org: ignored_repos ----

  def test_ignored_repos_excludes_by_bare_name
    http = StubHttp.new(
      repos_url(1) => page_response("org_repos_p1.json", link: NEXT_LINK),
      repos_url(2) => page_response("org_repos_p2.json")
    )
    result = GitHubToken.new(token: TOKEN, http: http).list_org(
      OrgRef.new(name: "cli", include_archived: true, include_forks: true, ignored_repos: ["kit"])
    )
    assert result.success?
    names = result.success.map(&:name)
    refute_includes names, "kit"
    assert_includes names, "cli"
  end

  def test_ignored_repos_excludes_by_full_name
    http = StubHttp.new(
      repos_url(1) => page_response("org_repos_p1.json", link: NEXT_LINK),
      repos_url(2) => page_response("org_repos_p2.json")
    )
    result = GitHubToken.new(token: TOKEN, http: http).list_org(
      OrgRef.new(name: "cli", include_archived: true, include_forks: true, ignored_repos: ["cli/go-gh"])
    )
    assert result.success?
    names = result.success.map(&:name)
    refute_includes names, "go-gh", "full_name match should exclude cli/go-gh"
    assert_includes names, "cli"
  end

  # ---- list_org: failures ----

  def test_list_org_missing_org_name_fails
    client = GitHubToken.new(token: TOKEN, http: StubHttp.new)
    result = client.list_org(OrgRef.new(name: ""))
    assert result.failure?
    assert_equal({org: "", reason: "missing org name"}, result.failure)
  end

  def test_list_org_non_2xx_is_failure_with_status
    http = StubHttp.new(
      repos_url(1) => Dry::Monads::Success(Response.new(status: 500, headers: {}, body: "[]"))
    )
    result = GitHubToken.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "cli"))
    assert result.failure?
    assert_equal({org: "cli", reason: "HTTP 500"}, result.failure)
  end

  def test_list_org_maps_transport_failure_into_reason
    transport = Dry::Monads::Failure({url: repos_url(1), error: "Net::OpenTimeout: operation timed out"})
    http = StubHttp.new(repos_url(1) => transport)
    result = GitHubToken.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "cli"))
    assert result.failure?
    assert_equal({org: "cli", reason: "Net::OpenTimeout: operation timed out"}, result.failure)
  end

  def test_list_org_invalid_json_is_failure
    http = StubHttp.new(
      repos_url(1) => Dry::Monads::Success(Response.new(status: 200, headers: {}, body: "<html>login page</html>"))
    )
    result = GitHubToken.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "cli"))
    assert result.failure?
    assert_equal "cli", result.failure[:org]
    assert_equal "invalid JSON from github", result.failure[:reason]
    refute_nil result.failure[:error]
  end

  def test_list_org_row_missing_full_name_is_invalid_json_failure
    http = StubHttp.new(
      repos_url(1) => Dry::Monads::Success(Response.new(
        status: 200, headers: {},
        body: "[{\"fork\": false, \"archived\": false}]"
      ))
    )
    result = GitHubToken.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "cli"))
    assert result.failure?
    assert_equal "invalid JSON from github", result.failure[:reason]
    refute_nil result.failure[:error]
  end

  def test_list_org_uses_org_name_verbatim_in_the_url
    http = StubHttp.new(
      repos_url(1, org: "My.Org_2") => page_response("org_repos_p1.json")
    )
    result = GitHubToken.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "My.Org_2"))
    assert result.success?
    assert_equal 1, http.requests.size
    assert_equal "#{API}/orgs/My.Org_2/repos?per_page=100&page=1", http.requests.first[:url]
  end
end
