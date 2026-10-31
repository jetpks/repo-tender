# frozen_string_literal: true

require "net/http"
require "uri"
require "dry/monads"

module RepoTender
  module Forge
    # The gem's single network egress seam: every HTTP exchange in lib/
    # goes through this class (the token-based GitHub and GitLab
    # clients inject it). Default implementation is stdlib net/http —
    # no new gemspec dependency. Deliberately narrow: GET only, no
    # redirects (neither target API redirects these endpoints — a
    # non-2xx status is a terminal answer, not a hop), and the
    # ambient process environment (proxy vars, TLS config) is honored
    # exactly as Net::HTTP honors it by default.
    #
    # A completed exchange is Success(Response) REGARDLESS of status —
    # status is data and the client decides what it means. Only
    # transport failures (connection refused, DNS, timeout) are
    # Failures; a bad URL argument is programmer error and raises.
    class HTTP
      extend Dry::Monads[:result]

      # One completed HTTP response. `headers` is the raw name→value
      # map as the transport produced it; `[]` gives case-insensitive
      # lookup (HTTP/1.1 casing today, any casing tomorrow).
      Response = Data.define(:status, :headers, :body) do
        def [](name)
          headers.each do |k, v|
            return v if k.to_s.casecmp?(name.to_s)
          end
          nil
        end
      end

      # GET `url`. Returns Success(Response) on any completed exchange
      # (2xx and non-2xx alike), Failure({url:, error:}) on transport
      # errors. Raises ArgumentError for input that is not an
      # http(s) URL.
      def get(url, headers: {})
        uri = parse_url(url)

        begin
          request = Net::HTTP::Get.new(uri.request_uri)
          headers.each { |name, value| request[name] = value }
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.request(request)
          end
          Dry::Monads::Success(Response.new(
            status: response.code.to_i,
            headers: response.each_header.to_h,
            body: response.body
          ))
        rescue => e
          # Transport errors (ECONNREFUSED, DNS failure, timeouts,
          # TLS failures…) are runtime facts, not programmer error —
          # rescue, never raise (AGENTS.md boundary rule).
          Dry::Monads::Failure({url: url, error: "#{e.class}: #{e.message}"})
        end
      end

      private

      def parse_url(url)
        uri = URI.parse(url.to_s)
        raise ArgumentError, "not an http(s) URL: #{url.inspect}" unless uri.scheme == "http" || uri.scheme == "https"
        uri
      rescue URI::InvalidURIError => e
        raise ArgumentError, "not a URL: #{url.inspect} (#{e.message})"
      end
    end
  end
end
