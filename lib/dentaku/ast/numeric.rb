require_relative "./literal"

module Dentaku
  module AST
    class Numeric < Literal
      def value(context = {})
        decimal_context = Dentaku.current_decimal_context
        return super unless decimal_context

        decimal_context.cast(@value)
      end
    end
  end
end
