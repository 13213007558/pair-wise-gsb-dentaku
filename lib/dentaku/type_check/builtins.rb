module Dentaku
  module TypeCheck
    # signatures for the functions Dentaku ships with; collection and
    # control-flow functions (IF, MAP, FILTER, REDUCE, ...) are handled
    # directly by the checker because they bind identifiers or need
    # branch-sensitive treatment
    module Builtins
      TABLE = {
        "not" => { params: [:logical], returns: :logical },
        "and" => { rest: :logical, returns: :logical },
        "or" => { rest: :logical, returns: :logical },
        "xor" => { rest: :logical, returns: :logical },
        "abs" => { params: [:numeric], returns: :numeric },
        "round" => { params: [:numeric], rest: :numeric, returns: :numeric },
        "roundup" => { params: [:numeric], rest: :numeric, returns: :numeric },
        "rounddown" => { params: [:numeric], rest: :numeric, returns: :numeric },
        # string functions stringify their text arguments at runtime,
        # so statically they accept anything
        "left" => { params: [:any, :numeric], returns: :string },
        "right" => { params: [:any, :numeric], returns: :string },
        "mid" => { params: [:any, :numeric, :numeric], returns: :string },
        "len" => { params: [:any], returns: :numeric },
        "find" => { params: [:any, :any], returns: :numeric },
        "substitute" => { params: [:any, :any, :any], returns: :string },
        "concat" => { rest: :any, returns: :string },
        "contains" => { params: [:any, :any], returns: :logical },
        "duration" => { params: [:numeric, :string], returns: :duration },
        "intercept" => {
          params: [[:array, :numeric, :n], [:array, :numeric, :n]],
          returns: :numeric
        }
      }.freeze

      MATH_ARRAY_RESULTS = %w[frexp lgamma].freeze

      def self.[](name)
        @cache ||= {}
        return @cache[name] if @cache.key?(name)

        @cache[name] =
          if (spec = TABLE[name])
            Signature.parse(spec, name: name)
          else
            math_signature(name)
          end
      end

      def self.math_signature(name)
        return nil unless MATH_FUNCTIONS.include?(name)

        method = Math.method(name)
        required = method.parameters.count { |kind, _| kind == :req }
        optional = method.parameters.any? { |kind, _| kind == :opt }
        returns = MATH_ARRAY_RESULTS.include?(name) ? [:array, :numeric, 2] : :numeric
        spec = { params: Array.new(required, :numeric), returns: returns }
        spec[:rest] = :numeric if optional
        Signature.parse(spec, name: name)
      end

      MATH_FUNCTIONS = Math.methods(false).map(&:to_s).freeze
    end
  end
end
