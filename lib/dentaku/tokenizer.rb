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
      original = string.to_s
      @original = original
      input, source_map = prepare_input(original)

      scanner_options = {
        case_sensitive: options.fetch(:case_sensitive, false),
        raw_date_literals: options.fetch(:raw_date_literals, true)
      }

      until input.empty?
        start_offset = input.bytesize
        token_count = @tokens.length
        scanned = TokenScanner.scanners(scanner_options).any? do |scanner|
          scanned, input = scan(input, scanner)
          scanned
        end

        unless scanned
          fail! :parse_error, at: input
        end

        assign_positions(@tokens[token_count..] || [], input, source_map, start_offset - input.bytesize)
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

          @tokens << token unless token.is?(:whitespace)
        end

        match_length = tokens.map(&:length).reduce(:+)
        [true, string[match_length..-1]]
      else
        [false, string]
      end
    end

    def strip_comments(input)
      input.gsub(/\/\*[^*]*\*+(?:[^*\/][^*]*\*+)*\//) do |comment|
        comment.gsub(/[^\n]/, ' ')
      end
    end

    def replace_aliases(string)
      return string unless @aliases.any?

      string.gsub!(alias_regex) do |match|
        match_regex = /^#{Regexp.escape(match)}$/i

        @aliases.detect do |(_key, aliases)|
          !aliases.grep(match_regex).empty?
        end.first
      end

      string
    end

    def alias_regex
      values = @aliases.values.flatten.join('|')
      /(?<=\p{Punct}|[[:space:]]|\A)(#{values})(?=\s*\()/i
    end

    def prepare_input(original)
      stripped = strip_comments(original.dup)
      transformed = +""
      source_map = []
      position = 0

      while position < stripped.length
        match = alias_prefix(stripped, position)

        if match
          append_alias(transformed, source_map, match[:canonical], match[:suffix], match[:start], match[:alias_length])
          position = match[:finish]
        else
          char = stripped[position]
          transformed << char
          source_map << position
          position += 1
        end
      end

      [transformed, source_map]
    end

    def alias_prefix(source, position)
      return nil if aliases.empty?

      aliases.each do |canonical, values|
        canonical_name = canonical.to_s
        values.each do |value|
          value_match = source[position, value.length]
          next unless value_match
          next unless value_match.casecmp?(value)

          after = source[position + value.length..]
          parenthesis_match = after&.match(/\A\s*\(/) || /\A\s*\(/.match('')
          next unless parenthesis_match

          suffix = parenthesis_match[0]
          matched_length = value.length + suffix.length
          return {
            start: position,
            finish: position + matched_length,
            canonical: canonical_name,
            suffix: suffix,
            alias_length: value.length
          }
        end
      end

      nil
    end

    def append_alias(output, source_map, canonical, suffix, start, alias_length)
      canonical.each_char { |char| output << char; source_map << start }
      suffix.each_char.with_index { |char, index| output << char; source_map << start + alias_length + index }
    end

    def assign_positions(new_tokens, remaining, source_map, consumed_length)
      transformed_end = source_map.length - remaining.length
      transformed_start = transformed_end - consumed_length
      token_start = transformed_start

      new_tokens.each do |token|
        length = token.raw_value.to_s.length
        token_finish = token_start + length

        leading = token.raw_value.to_s[/\A\s*/].to_s.length
        trailing = token.raw_value.to_s[/\s*\z/].to_s.length
        start_offset = [[token_start + leading, 0].max, source_map.length].min
        end_offset = [[token_finish - trailing, start_offset].max, source_map.length].min

        original_start = source_map[start_offset] || start_offset
        original_finish = end_offset == start_offset ? original_start + 1 : source_map[end_offset - 1] + 1
        token.instance_variable_set(
          :@source_range,
          SourceRange.from_offsets(@original, original_start, original_finish)
        )
        token_start = token_finish
      end
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
