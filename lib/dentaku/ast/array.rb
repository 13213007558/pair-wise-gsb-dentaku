require_relative "./node"
require_relative "../vector"

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
        values = @elements.map { |el| el.value(context) }
        if Dentaku::Vector.positioned?(context) && values.length == 1
          values.first
        elsif Dentaku::Vector.positioned?(context)
          values[Dentaku::Vector.position(context) % values.length]
        else
          Dentaku::CollectionArray.new(values)
        end
      end

      def dependencies(context = {})
        @elements.flat_map { |el| el.dependencies(context) }
      end

      def type
        nil
      end

      def accept(visitor)
        visitor.visit_array(self)
      end

      # Literal arrays are value collections, not batches.
      def tensor_shape(_context = {})
        []
      end

      private

      def compute_pure?
        @elements.all?(&:pure?)
      end
    end
  end
end
