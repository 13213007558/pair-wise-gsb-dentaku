require_relative "./node"

module Dentaku
  module AST
    class Array < Node
      def self.arity
      end

      def self.min_param_count
        0
      end

      def self.max_param_count
        Float::INFINITY
      end

      def initialize(*elements)
        @elements = *elements
      end

      def value(context = {})
        @elements.map { |el| el.value(context) }
      end

      def dependencies(context = {})
        @elements.flat_map { |el| el.dependencies(context) }
      end

      def type
        :array
      end

      def accept(visitor)
        visitor.visit_array(self)
      end

      attr_accessor :source_token

      def child_nodes
        @elements
      end

      private

      def compute_pure?
        @elements.all?(&:pure?)
      end
    end
  end
end
