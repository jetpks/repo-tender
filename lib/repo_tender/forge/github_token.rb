# frozen_string_literal: true

require "json"
require "repo_tender/forge/client"
require "repo_tender/forge/http"
require "repo_tender/config/model"

module RepoTender
  module Forge
    # Token-based GitHub REST client (Forge::Client impl) for the
    # server half: `Authorization: Bearer <token>` against
    # api.github.com instead of shelling out to `gh`. Selection is by
    # injection — Sync::Engine's default forge stays the gh-backed
    # Forge::GitHub; a host app constructs this client with its own
    # token (never a config.yaml field — no secrets in hand-editable
    # files). HTTP goes through the injectable Forge::HTTP egress
    # seam; everything here is offline-testable against a stubbed
    # transport. Per-row filtering is authoritative client-side
    # (gh-client precedent: API flags advisory, our filter definitive).
    class GitHubToken < Client
      # Hard page cap for org listings — `LIST_LIMIT` parity with the
      # gh client (100 rows/page × 10 pages = 1000; orgs with >1000
      # repos are out of scope). The cap is stop-and-succeed: page
      # 10's rows are kept.
      MAX_PAGES = 10

      def initialize(token:, http: HTTP.new, api_base: "https://api.github.com")
        raise ArgumentError, "token is required" if token.nil? || token.empty?
        @token = token
        @http = http
        @api_base = api_base
      end

      def check_authenticated
        result = @http.get("#{@api_base}/user", headers: auth_headers)
        return Dry::Monads::Failure({reason: result.failure[:error]}) if result.failure?

        case result.success.status
        when 200
          Dry::Monads::Success(:authenticated)
        when 401, 403
          Dry::Monads::Failure({reason: "github token rejected (HTTP #{result.success.status}); check the token and scopes"})
        else
          Dry::Monads::Failure({reason: "HTTP #{result.success.status} from /user"})
        end
      end

      def list_org(org_ref)
        return Dry::Monads::Failure({org: org_ref.name, reason: "missing org name"}) if org_ref.name.nil? || org_ref.name.empty?

        repos = []
        page = 1
        loop do
          url = "#{@api_base}/orgs/#{org_ref.name}/repos?per_page=100&page=#{page}"
          result = @http.get(url, headers: auth_headers)
          return Dry::Monads::Failure({org: org_ref.name, reason: result.failure[:error]}) if result.failure?

          response = result.success
          return Dry::Monads::Failure({org: org_ref.name, reason: "HTTP #{response.status}"}) unless (200..299).cover?(response.status)

          repos.concat(parse_rows(response.body, org_ref))

          # Follow the Link header's rel="next" entry, capped at
          # MAX_PAGES (stop-and-succeed — partial listing beats none).
          break unless page < MAX_PAGES && link_has_next?(response)
          page += 1
        end
        Dry::Monads::Success(repos)
      rescue JSON::ParserError => e
        Dry::Monads::Failure({org: org_ref.name, reason: "invalid JSON from github", error: e.message})
      end

      private

      def auth_headers
        {
          "Authorization" => "Bearer #{@token}",
          "Accept" => "application/vnd.github+json"
        }
      end

      # `Link: <…page=2>; rel="next", <…page=9>; rel="last"` — next-page
      # presence decides pagination. Case-insensitive header lookup keeps
      # this robust to any transport casing.
      def link_has_next?(response)
        link = response["Link"]
        !link.nil? && link.match?(%r{rel="next"})
      end

      # Maps one page's repo rows to RepoRefs, honoring
      # include_archived / include_forks / ignored_repos
      # (authoritative client-side, gh-client parity). A row missing
      # `full_name` violates the documented shape — invalid JSON, the
      # same Failure as an unparseable body.
      def parse_rows(body, org_ref)
        # body.to_s: a bodyless response (204) would otherwise raise
        # TypeError from JSON.parse(nil); "" parses as invalid JSON —
        # the Failure this contract promises, never an escape.
        rows = JSON.parse(body.to_s)
        ignored = org_ref.ignored_repos
        rows.map do |row|
          full_name = row["full_name"]
          raise JSON::ParserError, "repo row missing full_name: #{row.inspect}" if full_name.nil?

          next if !org_ref.include_archived && row["archived"]
          next if !org_ref.include_forks && row["fork"]

          owner, name = full_name.split("/", 2)
          next if ignored.include?(name) || ignored.include?(full_name)

          Config::RepoRef.new(
            host: org_ref.host,
            owner: owner,
            name: name
          )
        end.compact
      end
    end
  end
end
