require 'dentaku/token'
require 'dentaku/token_matcher'
require 'dentaku/token_scanner'

module Dentaku
  class Tokenizer
    attr_reader :aliases

    LPAREN = TokenMatcher.new(:grouping, :open)
    RPAREN = TokenMatcher.new(:grouping, :close)

    def tokenize(string, options = {})
      @nesting = 0
      @tokens  = []
      @aliases = options.fetch(:aliases, global_aliases)
      input, @source_map = prepare_input(string.to_s.dup)
      @offset  = 0

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
        assign_positions(tokens)

        tokens.each do |token|
          if token.empty?
            fail! :unexpected_zero_width_match,
                  token_category: token.category, at: string
          end

          @nesting += 1 if LPAREN == token
          @nesting -= 1 if RPAREN == token
          fail! :too_many_closing_parentheses if @nesting < 0

          @tokens << token unless token.is?(:whitespace)
        end

        match_length = tokens.map(&:length).reduce(:+)
        @offset += match_length
        [true, string[match_length..-1]]
      else
        [false, string]
      end
    end

    def strip_comments(input)
      # comments are erased but keep their footprint (and newlines) so that
      # token offsets still point at the original expression
      input.gsub(/\/\*[^*]*\*+(?:[^*\/][^*]*\*+)*\//) do |comment|
        comment.each_char.map { |c| c == "\n" ? c : ' ' }.join
      end
    end

    def replace_aliases(string)
      return string unless @aliases.any?

      string.gsub!(alias_regex) do |match|
        resolve_alias(match)
      end

      string
    end

    # returns [transformed_string, source_map] where source_map[i] is the
    # original-string offset corresponding to transformed offset i
    def prepare_input(original)
      stripped = strip_comments(original.dup)

      return [stripped, nil] unless @aliases.any?

      output = +""
      map = []
      pos = 0

      stripped.to_enum(:scan, alias_regex).each do
        match_data = Regexp.last_match
        match = match_data[0]
        replacement = resolve_alias(match)

        output << stripped[pos...match_data.begin(0)].to_s
        (pos...match_data.begin(0)).each { |i| map << i }
        output << replacement.to_s

        span = match_data.end(0) - match_data.begin(0)
        replacement.length.times do |k|
          map << match_data.begin(0) + [k, span - 1].min
        end

        pos = match_data.end(0)
      end

      output << stripped[pos..].to_s
      (pos...stripped.length).each { |i| map << i }

      [output, map]
    end

    def resolve_alias(match)
      match_regex = /\A#{Regexp.escape(match)}\z/i

      pair = @aliases.detect do |(_key, aliases)|
        !aliases.grep(match_regex).empty?
      end

      pair ? pair.first : match
    end

    # scanner matches may contain whitespace gaps (e.g. the function scanner
    # emits "name" and "(" for "name ("); anchor both ends so every token
    # lands at its true offset in the source string
    def assign_positions(tokens)
      base = @offset
      total = tokens.map(&:length).reduce(:+)
      cursor = base

      tokens.each do |token|
        if token.is?(:whitespace)
          cursor += token.length
          next
        end

        token.with_position(map_offset(cursor), map_offset(cursor + token.length - 1) + 1)
        cursor += token.length
      end

      if tokens.size > 1
        meaningful = tokens.reject { |t| t.is?(:whitespace) }
        last = meaningful.last
        unless last.nil?
          last.with_position(
            map_offset(base + total - 1) - last.raw_value.to_s.strip.length + 1,
            map_offset(base + total - 1) + 1
          )
        end
      end
    end

    def map_offset(offset)
      return offset if @source_map.nil?

      @source_map[[offset, @source_map.length - 1].min]
    end

    def alias_regex
      values = @aliases.values.flatten.join('|')
      /(?<=\p{Punct}|[[:space:]]|\A)(#{values})(?=\s*\()/i
    end

    private

    def global_aliases
      return {} unless Dentaku.respond_to?(:aliases)
      Dentaku.aliases
    end

    def fail!(reason, **meta)
      raise TokenizerError.for(reason, **meta)
    end
  end
end
