module Dentaku
  module AST
    class Nil < Node
      def initialize(token = nil)
        @token = token
      end

      def value(*)
        nil
      end

      def accept(visitor)
        visitor.visit_nil(self)
      end

      def type
        :nil
      end

      def source_token
        @token
      end
    end
  end
end
