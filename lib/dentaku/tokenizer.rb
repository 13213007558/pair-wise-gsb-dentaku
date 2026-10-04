require 'dentaku/token'
require 'dentaku/token_matcher'
require 'dentaku/token_scanner'
require 'dentaku/source_location'

module Dentaku
  class Tokenizer
    attr_reader :aliases

    LPAREN = TokenMatcher.new(:grouping, :open)
    RPAREN = TokenMatcher.new(:grouping, :close)
    COMMENT_REGEX = /\/\*[^*]*\*+(?:[^*\/][^*]*\*+)*\//

    def tokenize(string, options = {})
      @nesting = 0
      @tokens  = []
      @offset  = 0
      @aliases = options.fetch(:aliases, global_aliases)
      input, comment_map = strip_comments_with_map(string.to_s.dup)
      input, alias_map   = replace_aliases_with_map(input)
      @offset_map = alias_map.map { |i| comment_map[i] }

      scanner_options = {
        case_sensitive: options.fetch(:case_sensitive, false),
        raw_date_literals: options.fetch(:raw_date_literals, true)
      }

      until input.empty?
        scanned = TokenScanner.scanners(scanner_options).any? do |scanner|
          scanned, input = scan(input, scanner)
          scanned
        end

        unless scanned
          fail! :parse_error, at: input
        end
      end

      fail! :too_many_opening_parentheses if @nesting > 0

      @tokens
    end

    def last_token
      @tokens.last
    end

    def scan(string, scanner)
      if tokens = scanner.scan(string, last_token)
        tokens.each do |token|
          if token.empty?
            fail! :unexpected_zero_width_match,
                  token_category: token.category, at: string
          end

          @nesting += 1 if LPAREN == token
          @nesting -= 1 if RPAREN == token
          fail! :too_many_closing_parentheses if @nesting < 0

          token.loc = source_location(@offset, token.length)
          @offset += token.length

          @tokens << token unless token.is?(:whitespace)
        end

        match_length = tokens.map(&:length).reduce(:+)
        [true, string[match_length..-1]]
      else
        [false, string]
      end
    end

    def strip_comments(input)
      strip_comments_with_map(input).first
    end

    def replace_aliases(string)
      replace_aliases_with_map(string).first
    end

    private

    def strip_comments_with_map(input)
      gsub_with_map(input, COMMENT_REGEX) { "" }
    end

    def replace_aliases_with_map(string)
      return [string, (0...string.length).to_a] unless @aliases.any?

      gsub_with_map(string, alias_regex) do |match|
        match_regex = /^#{Regexp.escape(match)}$/i

        @aliases.detect do |(_key, aliases)|
          !aliases.grep(match_regex).empty?
        end.first
      end
    end

    # Rewrites +string+ like String#gsub, but also returns an index map
    # from offsets in the rewritten string back to offsets in the
    # original, so token locations can be reported against the user's
    # input even when comments or aliases changed its length.
    def gsub_with_map(string, regex)
      map = []
      result = +""
      offset = 0

      string.scan(regex) do
        match = Regexp.last_match
        result << string[offset...match.begin(0)]
        (offset...match.begin(0)).each { |i| map << i }

        replacement = yield(match[0]).to_s
        result << replacement
        replacement.length.times do |i|
          map << match.begin(0) + (i * match[0].length / replacement.length)
        end

        offset = match.end(0)
      end

      result << string[offset..-1]
      (offset...string.length).each { |i| map << i }

      [result, map]
    end

    def source_location(offset, length)
      first = @offset_map[offset] || offset
      last  = @offset_map[offset + length - 1] || (offset + length - 1)
      SourceLocation.new(first, last - first + 1)
    end

    def alias_regex
      values = @aliases.values.flatten.join('|')
      /(?<=\p{Punct}|[[:space:]]|\A)(#{values})(?=\s*\()/i
    end

    def global_aliases
      return {} unless Dentaku.respond_to?(:aliases)
      Dentaku.aliases
    end

    def fail!(reason, **meta)
      raise TokenizerError.for(reason, **meta)
    end
  end
end
