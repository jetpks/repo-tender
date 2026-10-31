# frozen_string_literal: true

require "test_helper"

# Forge::GitLab driven through a StubHttp collaborator at the
# Forge::HTTP seam — same pattern as github_token_test.rb. Bodies
# come from fixtures; transport metadata (status, X-Next-Page) is
# authored here. No network.
class ForgeGitLabTest < Minitest::Test
  GitLab = RepoTender::Forge::GitLab
  Response = RepoTender::Forge::HTTP::Response
  OrgRef = RepoTender::Config::OrgRef

  FIXTURES = File.expand_path("../../fixtures/gitlab_api", __dir__)
  API = "https://gitlab.com/api/v4"
  TOKEN = "glpat-testtoken123"

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

  def projects_url(page, group: "gitlab-org")
    "#{API}/groups/#{CGI.escape(group)}/projects?per_page=100&page=#{page}"
  end

  def user_response(status: 200)
    Dry::Monads::Success(Response.new(
      status: status,
      headers: {},
      body: fixture_body("user.json")
    ))
  end

  def page_response(fixture, next_page: nil)
    headers = {}
    headers["X-Next-Page"] = next_page unless next_page.nil?
    Dry::Monads::Success(Response.new(
      status: 200,
      headers: headers,
      body: fixture_body(fixture)
    ))
  end

  # ---- Constructor ----

  def test_token_is_required
    assert_raises(ArgumentError) { GitLab.new(token: nil) }
    assert_raises(ArgumentError) { GitLab.new(token: "") }
  end

  # ---- check_authenticated ----

  def test_check_authenticated_success_on_200_sends_private_token_header
    http = StubHttp.new("#{API}/user" => user_response)
    result = GitLab.new(token: TOKEN, http: http).check_authenticated
    assert result.success?, result.failure.inspect
    assert_equal :authenticated, result.success

    assert_equal 1, http.requests.size
    sent = http.requests.first
    assert_equal "#{API}/user", sent[:url]
    assert_equal TOKEN, sent[:headers]["PRIVATE-TOKEN"]
    assert_equal "application/json", sent[:headers]["Accept"]
  end

  def test_check_authenticated_failure_on_401
    http = StubHttp.new("#{API}/user" => user_response(status: 401))
    result = GitLab.new(token: "glpat-wrong", http: http).check_authenticated
    assert result.failure?
    assert_equal "gitlab token rejected (HTTP 401); check the token and scopes",
      result.failure[:reason]
  end

  def test_check_authenticated_failure_on_403
    http = StubHttp.new("#{API}/user" => user_response(status: 403))
    result = GitLab.new(token: "glpat-wrong", http: http).check_authenticated
    assert result.failure?
    assert_equal "gitlab token rejected (HTTP 403); check the token and scopes",
      result.failure[:reason]
  end

  def test_check_authenticated_failure_on_other_status
    http = StubHttp.new("#{API}/user" => user_response(status: 503))
    result = GitLab.new(token: TOKEN, http: http).check_authenticated
    assert result.failure?
    assert_equal "HTTP 503 from /user", result.failure[:reason]
  end

  def test_check_authenticated_maps_transport_failure_into_reason
    transport = Dry::Monads::Failure({url: "#{API}/user", error: "SocketError: getaddrinfo: Name or service not known"})
    http = StubHttp.new("#{API}/user" => transport)
    result = GitLab.new(token: TOKEN, http: http).check_authenticated
    assert result.failure?
    assert_equal "SocketError: getaddrinfo: Name or service not known", result.failure[:reason]
  end

  # ---- list_org: pagination via X-Next-Page ----

  def test_list_org_walks_two_pages_following_x_next_page
    http = StubHttp.new(
      projects_url(1) => page_response("group_projects_p1.json", next_page: "2"),
      projects_url(2) => page_response("group_projects_p2.json")
    )
    result = GitLab.new(token: TOKEN, http: http)
      .list_org(OrgRef.new(name: "gitlab-org", include_archived: true, include_forks: true))
    assert result.success?, result.failure.inspect
    names = result.success.map(&:name)
    assert_equal %w[deep-tool gitlab gitlab-docs gitlab-runner mirrored-project retired-tool], names.sort

    assert_equal [projects_url(1), projects_url(2)], http.requests.map { |r| r[:url] }
    assert http.requests.all? { |r| r[:headers]["PRIVATE-TOKEN"] == TOKEN },
      "every listing request carries the PRIVATE-TOKEN header"
  end

  def test_list_org_stops_when_x_next_page_is_absent
    http = StubHttp.new(projects_url(1) => page_response("group_projects_p1.json"))
    result = GitLab.new(token: TOKEN, http: http)
      .list_org(OrgRef.new(name: "gitlab-org", include_archived: true, include_forks: true))
    assert result.success?
    assert_equal 4, result.success.length
    assert_equal 1, http.requests.size, "no X-Next-Page header → exactly one page fetched"
  end

  def test_list_org_stops_when_x_next_page_is_empty
    http = StubHttp.new(
      projects_url(1) => page_response("group_projects_p1.json", next_page: "")
    )
    result = GitLab.new(token: TOKEN, http: http)
      .list_org(OrgRef.new(name: "gitlab-org", include_archived: true, include_forks: true))
    assert result.success?
    assert_equal 1, http.requests.size, "empty X-Next-Page means last page"
  end

  def test_list_org_stops_and_succeeds_at_ten_pages
    mapping = (1..10).each_with_object({}) do |page, acc|
      body = "[{\"path_with_namespace\": \"gitlab-org/p#{page}\", \"archived\": false}]"
      acc[projects_url(page)] = Dry::Monads::Success(Response.new(
        status: 200,
        headers: {"X-Next-Page" => (page + 1).to_s},
        body: body
      ))
    end
    http = StubHttp.new(mapping)
    result = GitLab.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "gitlab-org"))
    assert result.success?, result.failure.inspect
    assert_equal 10, result.success.length
    assert_equal 10, http.requests.size, "page 11 must never be fetched"
  end

  # ---- list_org: filters ----

  def test_list_org_excludes_archived_and_forks_by_default
    http = StubHttp.new(
      projects_url(1) => page_response("group_projects_p1.json", next_page: "2"),
      projects_url(2) => page_response("group_projects_p2.json")
    )
    result = GitLab.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "gitlab-org"))
    assert result.success?
    names = result.success.map(&:name).sort
    assert_equal %w[deep-tool gitlab gitlab-docs gitlab-runner], names,
      "archived (retired-tool) and fork (mirrored-project) rows are excluded by default"
  end

  def test_list_org_includes_archived_when_flagged
    http = StubHttp.new(projects_url(1) => page_response("group_projects_p1.json"))
    result = GitLab.new(token: TOKEN, http: http)
      .list_org(OrgRef.new(name: "gitlab-org", include_archived: true))
    assert result.success?
    names = result.success.map(&:name)
    assert_includes names, "retired-tool"
    refute_includes names, "mirrored-project"
  end

  def test_list_org_includes_fork_rows_when_flagged
    http = StubHttp.new(projects_url(1) => page_response("group_projects_p1.json", next_page: "2"),
      projects_url(2) => page_response("group_projects_p2.json"))
    result = GitLab.new(token: TOKEN, http: http)
      .list_org(OrgRef.new(name: "gitlab-org", include_forks: true))
    assert result.success?
    names = result.success.map(&:name)
    assert_includes names, "mirrored-project", "forked_from_project row must be included with include_forks"
    refute_includes names, "retired-tool"
  end

  # ---- list_org: path parsing ----

  def test_list_org_splits_path_with_namespace_subgroup_safe
    http = StubHttp.new(projects_url(1) => page_response("group_projects_p1.json"))
    result = GitLab.new(token: TOKEN, http: http)
      .list_org(OrgRef.new(host: "gitlab.com", name: "gitlab-org", include_archived: true))
    assert result.success?
    deep = result.success.find { |r| r.name == "deep-tool" }
    refute_nil deep
    assert_equal "gitlab-org/subgroup", deep.owner, "a/b/c → owner a/b, name c"
    assert_equal "gitlab.com", deep.host, "host comes from the OrgRef, not the API"
  end

  # ---- list_org: group-name escaping ----

  def test_list_org_escapes_nested_group_path_in_the_url
    http = StubHttp.new(projects_url(1, group: "mygroup/sub") => page_response("group_projects_p1.json"))
    result = GitLab.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "mygroup/sub"))
    assert result.success?
    assert_equal 1, http.requests.size
    assert_equal "#{API}/groups/mygroup%2Fsub/projects?per_page=100&page=1",
      http.requests.first[:url]
  end

  def test_list_org_sends_no_include_subgroups_param
    http = StubHttp.new(projects_url(1) => page_response("group_projects_p1.json"))
    GitLab.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "gitlab-org"))
    url = http.requests.first[:url]
    refute url.include?("include_subgroups"),
      "top-level-group-only listing is the GitHub-org parity; no include_subgroups param"
  end

  # ---- list_org: ignored_repos ----

  def test_ignored_repos_excludes_by_bare_name
    http = StubHttp.new(projects_url(1) => page_response("group_projects_p1.json"))
    result = GitLab.new(token: TOKEN, http: http).list_org(
      OrgRef.new(name: "gitlab-org", include_archived: true, ignored_repos: ["gitlab"])
    )
    assert result.success?
    names = result.success.map(&:name)
    refute_includes names, "gitlab"
    assert_includes names, "gitlab-runner"
  end

  def test_ignored_repos_excludes_by_full_path
    http = StubHttp.new(projects_url(1) => page_response("group_projects_p1.json"))
    result = GitLab.new(token: TOKEN, http: http).list_org(
      OrgRef.new(name: "gitlab-org", include_archived: true, ignored_repos: ["gitlab-org/gitlab-runner"])
    )
    assert result.success?
    names = result.success.map(&:name)
    refute_includes names, "gitlab-runner", "full path match should exclude gitlab-org/gitlab-runner"
    assert_includes names, "gitlab"
  end

  # ---- list_org: failures ----

  def test_list_org_missing_group_name_fails
    client = GitLab.new(token: TOKEN, http: StubHttp.new)
    result = client.list_org(OrgRef.new(name: ""))
    assert result.failure?
    assert_equal({org: "", reason: "missing org name"}, result.failure)
  end

  def test_list_org_non_2xx_is_failure_with_status
    http = StubHttp.new(
      projects_url(1) => Dry::Monads::Success(Response.new(status: 404, headers: {}, body: "[]"))
    )
    result = GitLab.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "gitlab-org"))
    assert result.failure?
    assert_equal({org: "gitlab-org", reason: "HTTP 404"}, result.failure)
  end

  def test_list_org_maps_transport_failure_into_reason
    transport = Dry::Monads::Failure({url: projects_url(1), error: "Errno::ECONNREFUSED: Connection refused"})
    http = StubHttp.new(projects_url(1) => transport)
    result = GitLab.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "gitlab-org"))
    assert result.failure?
    assert_equal({org: "gitlab-org", reason: "Errno::ECONNREFUSED: Connection refused"}, result.failure)
  end

  def test_list_org_invalid_json_is_failure
    http = StubHttp.new(
      projects_url(1) => Dry::Monads::Success(Response.new(status: 200, headers: {}, body: "{\"message\":"))
    )
    result = GitLab.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "gitlab-org"))
    assert result.failure?
    assert_equal "invalid JSON from gitlab", result.failure[:reason]
    refute_nil result.failure[:error]
  end

  def test_list_org_row_missing_path_with_namespace_is_invalid_json_failure
    http = StubHttp.new(
      projects_url(1) => Dry::Monads::Success(Response.new(
        status: 200, headers: {},
        body: "[{\"archived\": false}]"
      ))
    )
    result = GitLab.new(token: TOKEN, http: http).list_org(OrgRef.new(name: "gitlab-org"))
    assert result.failure?
    assert_equal "invalid JSON from gitlab", result.failure[:reason]
    refute_nil result.failure[:error]
  end
end
