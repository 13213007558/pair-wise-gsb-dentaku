require_relative "./node"

module Dentaku
  module AST
    class Array < Node
      attr_reader :elements

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
        path = context[Dentaku::ArrayValue::PATH_KEY]
        if path && !path.empty?
          element_context = Dentaku::ArrayValue.without_path(context)
          if regular_shape?(element_context)
            child = @elements[path.first]
            return nil unless child

            child_context = context.dup
            child_context[Dentaku::ArrayValue::PATH_KEY] = path.drop(1)
            return child.value(child_context)
          end
        end

        @elements.map { |el| el.value(context) }
      end

      def shape(context = {})
        cache = context[Dentaku::ArrayValue::SHAPE_CACHE_KEY] ||= {}
        key = [object_id, context.object_id]
        return cache[key] if cache.key?(key)

        return [0] if @elements.empty?

        child_shapes = @elements.map { |element| child_shape(element, context) }
        shape = child_shapes.all? { |child_shape| child_shape.is_a?(::Array) } &&
                child_shapes.uniq.one? ? [@elements.length] + child_shapes.first : nil
        cache[key] = shape
      end

      def regular_shape?(context = {})
        shape(context).is_a?(::Array)
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

      private

      def child_shape(element, context)
        return [] if element.is_a?(Literal)

        Dentaku::ArrayValue.shape(element, context)
      end

      def compute_pure?
        @elements.all?(&:pure?)
      end
    end
  end
end
