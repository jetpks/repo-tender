# frozen_string_literal: true

require "test_helper"

# Forge::HTTP's Response contract, exercised without any socket: the
# egress seam's real transport (Net::HTTP) is exercised only in
# production — the offline suite stubs the seam, never the network.
class ForgeHTTPTest < Minitest::Test
  HTTP = RepoTender::Forge::HTTP
  Response = RepoTender::Forge::HTTP::Response

  def test_response_is_a_data_with_status_headers_body
    response = Response.new(
      status: 200,
      headers: {"Content-Type" => "application/json"},
      body: "[]"
    )
    assert_equal 200, response.status
    assert_equal({"Content-Type" => "application/json"}, response.headers)
    assert_equal "[]", response.body
  end

  def test_header_lookup_is_case_insensitive
    response = Response.new(
      status: 200,
      headers: {"Link" => "<https://api.github.com/orgs/cli/repos?per_page=100&page=2>; rel=\"next\""},
      body: "[]"
    )
    expected = "<https://api.github.com/orgs/cli/repos?per_page=100&page=2>; rel=\"next\""
    assert_equal expected, response["Link"]
    assert_equal expected, response["link"]
    assert_equal expected, response["LINK"]
  end

  def test_header_lookup_case_insensitive_against_downcased_transport_keys
    # The real transport hands downcased header names ("link",
    # "x-next-page"); callers ask in canonical case. Both directions
    # must meet in the middle.
    response = Response.new(
      status: 200,
      headers: {"link" => "page-2-url", "x-next-page" => "2"},
      body: "[]"
    )
    assert_equal "page-2-url", response["Link"]
    assert_equal "2", response["X-Next-Page"]
  end

  def test_header_lookup_returns_nil_for_missing_header
    response = Response.new(status: 404, headers: {}, body: "[]")
    assert_nil response["Link"]
    assert_nil response["x-next-page"]
  end

  def test_get_raises_argument_error_for_non_http_s_url
    ["ftp://example.com/repo.git", "file:///tmp/state", "example.com", "", nil].each do |bad|
      assert_raises(ArgumentError, "expected ArgumentError for #{bad.inspect}") do
        HTTP.new.get(bad)
      end
    end
  end

  def test_get_raises_argument_error_for_unparseable_url
    assert_raises(ArgumentError) { HTTP.new.get("not a url") }
  end
end
