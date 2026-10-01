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
      input    = strip_comments(string.to_s.dup)
      input    = replace_aliases(input)
      @source = input

      scanner_options = {
        case_sensitive: options.fetch(:case_sensitive, false),
        raw_date_literals: options.fetch(:raw_date_literals, true)
      }

      until input.empty?
        token_offset = @source.length - input.length
        scanned = TokenScanner.scanners(scanner_options).any? do |scanner|
          scanned, input, token_offset = scan(input, scanner, token_offset)
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

    def scan(string, scanner, offset = 0)
      if tokens = scanner.scan(string, last_token)
        token_offset = offset
        tokens.each do |token|
          prefix = original_source[0...token_offset]
          token.line = prefix.count("\n") + 1
          token.column = token_offset - (prefix.rindex("\n") || -1)
          token_offset += token.to_s.length
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
        [true, string[match_length..-1], offset]
      else
        [false, string, offset]
      end
    end

    def original_source
      @source ||= ''
    end

    def strip_comments(input)
      input.gsub(/\/\*[^*]*\*+(?:[^*\/][^*]*\*+)*\//) { |comment| comment.gsub(/[^\n]/, ' ') }
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
