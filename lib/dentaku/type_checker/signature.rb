module Dentaku
  module TypeChecker
    # A function signature: parameter types and a result type, optionally
    # polymorphic. Examples:
    #
    #   Signature.parse("numeric, numeric -> numeric")
    #   Signature.parse("array(T) -> T")
    #   Signature.new([Type.array(Type.variable(:T))], Type.variable(:T))
    #
    # A signature is a template. Each call instantiates it with fresh
    # unification variables so type variables never leak between calls.
    class Signature
    attr_reader :params, :result, :variadic, :optional_count

      def variadic?
        @variadic
      end

    def initialize(params, result, variadic: false, optional_count: 0)
      @params = params
      @result = result
      @variadic = variadic
      @optional_count = optional_count
      end

      ARROW = /\s*(?:->|=>)\s*/.freeze

      def self.parse(spec)
        raise TypeError, "empty function signature" if spec.to_s.strip.empty?

        left, right = spec.split(ARROW, 2)
        raise TypeError, "function signature must contain ->: #{spec}" if right.nil?

        params = left.strip.empty? ? [] : split_params(left).map { |p| Type.parse(p) }
        result = Type.parse(right)
        variadic = left.include?('*')
        optional_count = split_params(left).count { |p| p.strip.end_with?('?') }
        new(params, result, variadic: variadic, optional_count: optional_count)
      end

      # separate top-level parameters while keeping array(T) together
      def self.split_params(string)
        params = []
        depth = 0
        current = ""

        string.each_char do |char|
          case char
          when '(' then depth += 1; current << char
          when ')'
            depth -= 1
            raise TypeError, "unbalanced ) in signature: #{string}" if depth.negative?
            current << char
          when ',' then
            if depth.zero?
              params << current.strip
              current = ""
            else
              current << char
            end
          else current << char
          end
        end
        raise TypeError, "unbalanced ( in signature: #{string}" unless depth.zero?

        params << current.strip unless current.strip.empty?
        params
      end

      def labels
        ([result] + params).flat_map { |t| collect_vars(t) }.uniq
      end

      # fresh instantiation for one call site
      def instantiate(serial)
        mapping = labels.to_h { |label| [label, Type.flex(serial.next_id)] }
        [params.map { |p| substitute(p, mapping) },
         substitute(result, mapping)]
      end

      private

      def collect_vars(type)
        case type
        when Type::Var then [type.label]
        when Type::ArrayT then collect_vars(type.element)
        else []
        end
      end

      def substitute(type, mapping)
        case type
        when Type::Var then mapping.fetch(type.label) { type }
        when Type::ArrayT then Type.array(substitute(type.element, mapping))
        else type
        end
      end
    end
  end
end
