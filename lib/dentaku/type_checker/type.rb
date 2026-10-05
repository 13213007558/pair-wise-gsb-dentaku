module Dentaku
  module TypeChecker
    # Static types used by the formula type checker. Types are value
    # objects built from user declarations and function signatures:
    #
    #   numeric / integer / logical(bool) / string / date / duration
    #   array(T)                       -- homogeneous array of T
    #   variable(:T)                  -- a (per-call) polymorphic variable
    #   any(:source, :range)          -- unknown, unifies with anything
    #
    # Type equality is structural; unification lives in Unifier.
    module Type
      SCALARS = %i[numeric integer logical string date duration].freeze
      ALIASES = { bool: :logical, boolean: :logical, number: :numeric,
                  text: :string, str: :string, datetime: :date }.freeze

      Scalar = Struct.new(:name) do
        def to_s
          name.to_s
        end
      end

      ArrayT = Struct.new(:element) do
        def to_s
          "array(#{element})"
        end
      end

      # a polymorphic variable as written in a signature, e.g. T in array(T) -> T
      Var = Struct.new(:label) do
        def to_s
          label.to_s
        end
      end

      # a unification variable generated while checking one formula
      Flex = Struct.new(:id) do
        def to_s
          "?#{id}"
        end
      end

      # an unknown type (undeclared dependency or function without a
      # signature). Unifies with everything but is reported separately so
      # callers know the result is not fully determined.
      Any = Struct.new(:source, :range) do
        def to_s
          source.to_s
        end
      end

      class << self
        def scalar(name)
          normalized = ALIASES.fetch(name.to_sym, name.to_sym)
          raise TypeError, "unknown type: #{name}" unless SCALARS.include?(normalized)

          Scalar.new(normalized)
        end

        def array(element)
          ArrayT.new(element)
        end

        def variable(label)
          Var.new(label.to_sym)
        end

        def flex(id)
          Flex.new(id)
        end

        def any(source = :unknown, range = nil)
          Any.new(source, range)
        end

        def numeric?(t)
          t.is_a?(Scalar) && t.name == :numeric
        end

        def logical?(t)
          t.is_a?(Scalar) && t.name == :logical
        end

        def string?(t)
          t.is_a?(Scalar) && t.name == :string
        end

        def date?(t)
          t.is_a?(Scalar) && t.name == :date
        end

        def array?(t)
          t.is_a?(ArrayT)
        end

        def var?(t)
          t.is_a?(Var)
        end

        def flex?(t)
          t.is_a?(Flex)
        end

        def any?(t)
          t.is_a?(Any)
        end

        # Parse the small signature DSL:
        #   "numeric", "bool", "array(string)", "T", "array(T)"
        def parse(string)
          Parser.new(string.to_s).parse_type
        end
      end

      # Recursive-descent parser for the type expression grammar
      class Parser
        TYPE_TOKEN = /array|\w+[*?]?|[(),\[\]]/.freeze

        def initialize(source)
          @source = source
          @tokens = source.scan(TYPE_TOKEN)
          @pos = 0
        end

        def parse_type
          type = parse_single
          unless @pos == @tokens.length
            raise TypeError, "unexpected type token near #{@source}"
          end

          type
        end

        def parse_single
          parse_atom
        end

        private

        def take
          tok = @tokens[@pos]
          @pos += 1
          tok
        end

        def parse_atom
          token = take
          raise TypeError, "missing type" if token.nil?

          case token
          when 'array'
            parse_array
          when *SCALARS.map(&:to_s), *SCALARS.map { |s| "#{s}*" }
            Type.scalar(token.delete_suffix('*'))
          when *SCALARS.map { |s| "#{s}?" }
            Type.scalar(token.delete_suffix('?'))
          when *ALIASES.keys.map(&:to_s), *ALIASES.keys.map { |s| "#{s}*" }
            Type.scalar(token.delete_suffix('*').downcase)
          when *ALIASES.keys.map { |s| "#{s}?" }
            Type.scalar(token.delete_suffix('?').downcase)
          else
            if token =~ /\A[A-Z_]\w*[*?]?\z/
              Type.variable(token.delete_suffix('*').delete_suffix('?'))
            else
              raise TypeError, "unknown type: #{token}"
            end
          end
        end

        def parse_array
          opening = take
          raise TypeError, "expected ( after array" unless opening == '('

          element = parse_single
          closing = take
          raise TypeError, "expected ) after array element type" unless closing == ')'

          Type.array(element)
        end
      end
    end
  end
end
