# frozen_string_literal: true

require "json"
require "cgi"
require "repo_tender/forge/client"
require "repo_tender/forge/http"
require "repo_tender/config/model"

module RepoTender
  module Forge
    # GitLab v4 REST client (Forge::Client impl) for the server half:
    # `PRIVATE-TOKEN: <token>` against gitlab.com (or a self-hosted
    # api_base). Behind the same two-method interface as the GitHub
    # clients, so the engine selects it by injection exactly like
    # Forge::GitHubToken. HTTP goes through the injectable Forge::HTTP
    # egress seam; per-row filtering is authoritative client-side.
    class GitLab < Client
      # Hard page cap — LIST_LIMIT parity with the GitHub clients
      # (100 rows/page × 10 pages = 1000; groups with >1000 projects
      # are out of scope). Stop-and-succeed at the cap.
      MAX_PAGES = 10

      def initialize(token:, http: HTTP.new, api_base: "https://gitlab.com/api/v4")
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
          Dry::Monads::Failure({reason: "gitlab token rejected (HTTP #{result.success.status}); check the token and scopes"})
        else
          Dry::Monads::Failure({reason: "HTTP #{result.success.status} from /user"})
        end
      end

      def list_org(org_ref)
        return Dry::Monads::Failure({org: org_ref.name, reason: "missing org name"}) if org_ref.name.nil? || org_ref.name.empty?

        repos = []
        page = 1
        loop do
          # Group path URL-escaped per GitLab's docs (a nested group's
          # `/` arrives as %2F). No include_subgroups param — a
          # top-level group's own projects is the parity match for a
          # GitHub org listing (grounds D5).
          url = "#{@api_base}/groups/#{CGI.escape(org_ref.name)}/projects?per_page=100&page=#{page}"
          result = @http.get(url, headers: auth_headers)
          return Dry::Monads::Failure({org: org_ref.name, reason: result.failure[:error]}) if result.failure?

          response = result.success
          return Dry::Monads::Failure({org: org_ref.name, reason: "HTTP #{response.status}"}) unless (200..299).cover?(response.status)

          repos.concat(parse_rows(response.body, org_ref))

          # Follow X-Next-Page: present and non-empty → next page,
          # absent/empty → last page. Capped at MAX_PAGES
          # (stop-and-succeed — partial listing beats none).
          next_page = response["X-Next-Page"]
          break if next_page.nil? || next_page.empty? || page >= MAX_PAGES
          page += 1
        end
        Dry::Monads::Success(repos)
      rescue JSON::ParserError => e
        Dry::Monads::Failure({org: org_ref.name, reason: "invalid JSON from gitlab", error: e.message})
      end

      private

      def auth_headers
        {
          "PRIVATE-TOKEN" => @token,
          "Accept" => "application/json"
        }
      end

      # Maps one page's project rows to RepoRefs. `path_with_namespace`
      # splits subgroup-safe: `a/b/c` → owner `a/b`, name `c` (all but
      # the last segment is the owner). A fork is a row carrying the
      # `forked_from_project` key (present only on forks); `archived`
      # is a plain boolean. ignored_repos matches the bare name (last
      # segment) or the full path. A row missing the required key
      # violates the documented shape — invalid JSON, same Failure as
      # an unparseable body.
      def parse_rows(body, org_ref)
        # body.to_s: a bodyless response (204) would otherwise raise
        # TypeError from JSON.parse(nil); "" parses as invalid JSON —
        # the Failure this contract promises, never an escape.
        rows = JSON.parse(body.to_s)
        ignored = org_ref.ignored_repos
        rows.map do |row|
          path = row["path_with_namespace"]
          raise JSON::ParserError, "project row missing path_with_namespace: #{row.inspect}" if path.nil?

          next if !org_ref.include_archived && row["archived"]
          next if !org_ref.include_forks && row.key?("forked_from_project")

          parts = path.split("/")
          name = parts.pop
          owner = parts.join("/")
          next if ignored.include?(name) || ignored.include?(path)

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
