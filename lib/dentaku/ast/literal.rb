module Dentaku
  module AST
    class Literal < Node
      attr_reader :type

      def initialize(token)
        @token = token
        @value = token.value
        @type  = token.category
      end

      def value(context = {})
        execution = context[Dentaku::Calculator::DECIMAL_CONTEXT_KEY]
        return @value unless execution && @type == :numeric

        value = case @value
                when ::Integer, ::BigDecimal
                  execution.decimal(@value)
                else
                  execution.decimal(@token.raw_value.to_s)
                end
        execution.fit(value)
      end

      def dependencies(*)
        []
      end

      def accept(visitor)
        visitor.visit_literal(self)
      end

      def quoted
        @token.raw_value || value.to_s
      end
      alias_method :to_s, :quoted
    end
  end
end
