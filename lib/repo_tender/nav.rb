# frozen_string_literal: true

module RepoTender
  # Fuzzy navigator over on-disk source checkouts.
  #
  # Checkouts live at base_dir/<host>/<owner>/<name> (depth-3 dirs).
  # Matching is a case-insensitive SUBSEQUENCE against "owner/name" —
  # host is excluded from the match but is part of the resolved path.
  #
  # Ranking is fzf-inspired: contiguity bonus, word-boundary bonus,
  # earliness (earlier first match wins). Ties break by target string
  # asc then host asc — deterministic total order.
  module Nav
    # Enumerate all depth-3 directories under base_dir.
    # Returns array of hashes: {host:, owner:, name:, target:, path:}.
    def self.scan(base_dir)
      pattern = File.join(base_dir, "*", "*", "*")
      prefix = base_dir.chomp("/") + "/"
      # paths:exempt - layout intent (depth-3 checkout scan); repo_tender is deliberately independent of space_core and must not require it
      Dir.glob(pattern).filter_map do |path|
        next unless File.directory?(path)
        relative = path.delete_prefix(prefix)
        parts = relative.split("/")
        next unless parts.length == 3
        host, owner, name = parts
        {host:, owner:, name:, target: "#{owner}/#{name}", path:}
      end
    end

    # Pure: find the leftmost match positions of query chars (case-insensitive)
    # as a subsequence into target. Returns an array of integer indices, or nil
    # if the query is not a subsequence of the target.
    def self.match_positions(query, target)
      q = query.downcase
      t = target.downcase
      positions = []
      qi = 0
      t.each_char.with_index do |c, i|
        if c == q[qi]
          positions << i
          qi += 1
          return positions if qi == q.length
        end
      end
      nil
    end

    # Pure: compute a score for a set of match positions within target_lower.
    # Higher score = better match.
    #   contiguity: each consecutive pair of matched indices scores +10
    #   word boundary: each position at start of string or right after
    #     '/', '-', '_' scores +5
    #   earliness: subtract the first matched position (earlier = higher score)
    def self.score_match(positions, target_lower)
      contiguity = positions.each_cons(2).count { |a, b| b == a + 1 } * 10
      boundary = positions.count do |p|
        p == 0 || "/\\-_".include?(target_lower[p - 1])
      end * 5
      earliness = -positions.first
      contiguity + boundary + earliness
    end

    # Pure: match and rank a list of entry hashes against query.
    # Returns entries annotated with :score, sorted best-first.
    # Tie-break: target asc, then host asc.
    def self.rank(entries, query)
      scored = entries.filter_map do |e|
        t = e[:target].downcase
        positions = match_positions(query, t)
        next unless positions
        score = score_match(positions, t)
        e.merge(score:)
      end
      scored.sort_by { |e| [-e[:score], e[:target], e[:host]] }
    end

    # Cd-contract executor. Scans base_dir for checkouts, fuzzy-matches
    # query, applies the 0/1/many contract:
    #   - exactly one match  → absolute path on last stdout line, returns 0
    #   - zero matches       → message on stderr, returns 1
    #   - multiple matches   → ranked candidates on stdout, returns 1
    def self.dispatch(query, stdout, stderr, base_dir)
      entries = scan(base_dir)
      matches = rank(entries, query)

      case matches.length
      when 0
        stderr.puts "repo-tender: no match for '#{query}'"
        1
      when 1
        stdout.puts matches.first[:path]
        0
      else
        matches.each { |m| stdout.puts "#{m[:host]}/#{m[:target]}" }
        1
      end
    end
  end
end
