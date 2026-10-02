require_relative './operation'

module Dentaku
  module AST
    class Comparator < Operation
      def self.precedence
        5
      end

      def type
        :logical
      end

      def operator
        raise NotImplementedError
      end

      def value(context = {})
        l = validate_value(cast(left.value(context), context))
        r = validate_value(cast(right.value(context), context))

        l.public_send(operator, r)
      rescue ::ArgumentError, ::TypeError => e
        raise Dentaku::ArgumentError.for(:incompatible_type, actual: r, expected: l.class), e.message
      end

      private

      def cast(val, context = {})
        execution = context[Dentaku::Calculator::DECIMAL_CONTEXT_KEY]
        if execution
          numeric_string = val.is_a?(::String) && Dentaku::NumericParser.match(val)
          numeric_value = val.is_a?(::Integer) || val.is_a?(::BigDecimal)
          return execution.fit(execution.decimal(val)) if numeric_string || numeric_value
          return val
        end

        return val unless val.is_a?(::String)

        Dentaku::NumericParser.parse_string(val) || val
      end

      def validate_value(value)
        unless value.respond_to?(operator)
          raise Dentaku::ArgumentError.for(:invalid_operator, operation: self.class, operator: operator)
        end

        value
      end
    end

    class LessThan < Comparator
      def operator
        :<
      end
    end

    class LessThanOrEqual < Comparator
      def operator
        :<=
      end
    end

    class GreaterThan < Comparator
      def operator
        :>
      end
    end

    class GreaterThanOrEqual < Comparator
      def operator
        :>=
      end
    end

    class NotEqual < Comparator
      def operator
        :!=
      end
    end

    class Equal < Comparator
      def operator
        :==
      end

      def display_operator
        "="
      end
    end
  end
end
