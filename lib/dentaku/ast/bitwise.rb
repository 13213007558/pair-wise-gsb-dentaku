require_relative './operation'
require_relative './vectorizable'

module Dentaku
  module AST
    class Bitwise < Operation
      include Vectorizable

      def value(context = {})
        vectorize_binary(left, right, context) do |lhs, rhs|
          lhs.public_send(operator, rhs)
        rescue NoMethodError
          raise Dentaku::ArgumentError.for(:incompatible_type, actual: lhs, expected: Integer),
                "#{self.class} requires integer operands, but got #{lhs.class}"
        rescue TypeError
          raise Dentaku::ArgumentError.for(:incompatible_type, actual: rhs, expected: Integer),
                "#{self.class} requires integer operands, but got #{rhs.class}"
        end
      end
    end

    class BitwiseOr < Bitwise
      def operator
        :|
      end
    end

    class BitwiseAnd < Bitwise
      def operator
        :&
      end
    end

    class BitwiseShiftLeft < Bitwise
      def operator
        :<<
      end
    end

    class BitwiseShiftRight < Bitwise
      def operator
        :>>
      end
    end
  end
end
