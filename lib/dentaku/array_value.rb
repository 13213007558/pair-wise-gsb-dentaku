module Dentaku
  class ArrayValue
    PATH_KEY = "__dentaku_array_path__".freeze
    CACHE_KEY = "__dentaku_array_cache__".freeze
    SHAPE_CACHE_KEY = "__dentaku_array_shape_cache__".freeze

    def self.evaluate(node, context)
      shape = shape(node, context)
      return node.value(context) unless vector_shape?(node, shape)

      errors = []
      result = traverse(node, context, shape, [], errors)
      return result if errors.empty?

      raise ArrayEvaluationError.new(errors, result)
    end

    def self.shape(node, context = {}, suppress_whole: false, broadcast: false)
      case node
      when AST::Array
        node.shape(context)
      when AST::Identifier
        broadcast && identifier_shape(node, context)
      when AST::Grouping
        shape(node.instance_variable_get(:@node), context,
              suppress_whole: suppress_whole, broadcast: broadcast)
      when AST::If
        broadcast(
          shape(node.predicate, context, suppress_whole: suppress_whole, broadcast: true),
          shape(node.left, context, suppress_whole: true, broadcast: true),
          shape(node.right, context, suppress_whole: true, broadcast: true)
        )
      when AST::Negation
        shape(node.node, context, suppress_whole: suppress_whole, broadcast: broadcast)
      when AST::Percentage
        shape(node.left, context, suppress_whole: suppress_whole, broadcast: broadcast)
      when AST::Literal, AST::Nil
        []
      when AST::Arithmetic
        arithmetic_shape(node, context)
      when AST::Operation
        broadcast(
          shape(node.left, context, suppress_whole: suppress_whole, broadcast: true),
          shape(node.right, context, suppress_whole: suppress_whole, broadcast: true)
        )
      when AST::Function
        function_shape(node, context, suppress_whole, broadcast)
      else
        nil
      end
    end

    def self.value_at(node, context, path)
      context[CACHE_KEY] ||= {}
      context[SHAPE_CACHE_KEY] ||= {}
      previous_path = context[PATH_KEY]
      context[PATH_KEY] = path
      node.value(context)
    ensure
      if previous_path.nil?
        context.delete(PATH_KEY)
      else
        context[PATH_KEY] = previous_path
      end
    end

    def self.index_value(value, path)
      return value if path.nil?

      shape = shape_of_value(value)
      return value unless value.is_a?(::Array) && shape && !shape.empty? && path.length >= shape.length

      path.last(shape.length).each_with_index.reduce(value) do |current, (index, dimension)|
        current[shape[dimension] == 1 ? 0 : index]
      end
    end

    def self.broadcast(*shapes)
      known = shapes.compact
      return nil if known.empty?
      return known.first if known.one?

      rank = known.map(&:length).max
      Array.new(rank) do |dimension|
        sizes = known.map { |shape| shape[dimension - rank + shape.length] }.compact
        sizes.reduce do |selected, size|
          next size if selected == 1
          next selected if size == 1
          next selected if selected == size

          raise ShapeMismatch.new(shapes)
        end
      end
    end

    def self.shape_of_value(value)
      shape = regular_shape(value)
      return nil if shape.nil? || shape.empty?

      shape
    end

    def self.regular_shape(value)
      return nil unless value.is_a?(::Array)
      return [0] if value.empty?

      child_shapes = value.map { |child| child.is_a?(::Array) ? regular_shape(child) : [] }
      return nil if child_shapes.any?(&:nil?)
      return nil unless child_shapes.uniq.one?

      [value.length] + child_shapes.first
    end

    def self.without_path(context)
      context.dup.tap { |copy| copy.delete(PATH_KEY) }
    end

    def self.traverse(node, context, shape, path, errors)
      if shape.empty?
        begin
          value_at(node, context, path)
        rescue StandardError => error
          element_error = error.is_a?(ElementError) ? error : ElementError.new(path, error)
          errors << element_error
          nil
        end
      else
        head, *rest = shape
        Array.new(head) do |index|
          traverse(node, context, rest, path + [index], errors)
        end
      end
    end

    def self.vector_shape?(node, shape)
      return false unless shape.is_a?(::Array) && !shape.empty?
      return true if node.is_a?(AST::Array) || node.is_a?(AST::Operation) || node.is_a?(AST::If) || node.is_a?(AST::Grouping)
      return true if node.is_a?(AST::Function) && node.class.array_mode == :elementwise

      false
    end

    def self.identifier_shape(node, context)
      value = context[node.identifier]
      value = value.value(context) if value.is_a?(AST::Node)
      value.is_a?(::Array) ? shape_of_value(value) : nil
    end

    def self.arithmetic_shape(node, context)
      left_shape = arithmetic_value_shape(node.left, context)
      right_shape = arithmetic_value_shape(node.right, context)
      return nil if left_shape.nil? && right_shape.nil?

      broadcast(left_shape || [], right_shape || [])
    end

    def self.arithmetic_value_shape(node, context)
      case node
      when AST::Arithmetic
        arithmetic_shape(node, context)
      when AST::Negation
        arithmetic_value_shape(node.node, context)
      when AST::Percentage
        arithmetic_value_shape(node.left, context)
      when AST::Function
        return nil unless node.class.array_mode == :elementwise

        function_shape(node, context, false, true)
      when AST::Identifier
        shape = identifier_shape(node, context)
        shape if shape.nil? || numeric_value?(context[node.identifier])
      when AST::Array
        node.shape(context)
      when AST::Literal
        node.value(context).is_a?(::Numeric) ? [] : nil
      when AST::Grouping
        arithmetic_value_shape(node.instance_variable_get(:@node), context)
      else
        []
      end
    end

    def self.numeric_value?(value)
      case value
      when Numeric
        true
      when ::Array
        return true if value.empty?

        value.all? { |child| numeric_value?(child) }
      else
        false
      end
    end

    def self.function_shape(node, context, suppress_whole, broadcast)
      argument_broadcast = broadcast || node.class.array_mode == :elementwise
      argument_shapes = node.args.map do |arg|
        shape(arg, context, suppress_whole: suppress_whole, broadcast: argument_broadcast)
      end
      return broadcast(*argument_shapes) if node.class.array_mode == :elementwise
      return nil if suppress_whole

      whole_function_shape(node, context, argument_shapes)
    end

    def self.whole_function_shape(node, context, _argument_shapes)
      return nil unless node.pure?

      shape_of_value(node.value(without_path(context)))
    end

    private_class_method :traverse, :vector_shape?, :function_shape, :whole_function_shape
  end

  class ElementError < BaseError
    attr_reader :index, :source

    def initialize(index, source)
      @index = index
      @source = source
      super("error at array index #{index.inspect}: #{source.message}")
    end
  end

  class ArrayEvaluationError < BaseError
    attr_reader :element_errors, :partial_results

    def initialize(element_errors, partial_results)
      @element_errors = element_errors
      @partial_results = partial_results
      super("array evaluation failed at #{element_errors.length} index(es)")
    end

    def indices
      element_errors.map(&:index)
    end
  end

  class ShapeMismatch < BaseError
    attr_reader :shapes

    def initialize(shapes)
      @shapes = shapes
      super("array shapes are not compatible: #{shapes.map(&:inspect).join(', ')}")
    end
  end
end
