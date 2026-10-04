# frozen_string_literal: true

require_relative "exceptions"

module Dentaku
  # Marker for arrays written as literals in an expression (`{1, 2, 3}`).
  # Literal arrays are value collections with list semantics (concatenation
  # on +, difference on -), not batch tensors. Arrays supplied through data
  # are batches and broadcast element-wise.
  class CollectionArray < ::Array
  end

  # Multi-dimensional batch values.
  #
  # A Tensor wraps a Ruby Array together with an explicit shape. The shape
  # distinguishes empty dimensions ([] alone cannot tell an empty row axis
  # from an empty column axis) and separates regular tensors from ragged
  # nested arrays. Values that are not Tensors are scalars; they broadcast
  # against every shape.
  class Tensor
    attr_reader :shape

    def initialize(value, shape = nil)
      inferred = self.class.send(:regular_shape, value)
      shape ||= inferred || [value.length]
      @shape = shape.map { |dim| Integer(dim) }.freeze
      @value = value
      @regular = !inferred.nil?
      freeze
    end

    # Regularly nested arrays become multi-dimensional tensors. A nested
    # array whose siblings disagree is ragged: it keeps its outer axis and
    # its irregular members stay opaque to broadcasting.
    def self.wrap(value)
      case value
      when Tensor then value
      when CollectionArray then value
      when ::Array then new(value)
      else value
      end
    end

    def self.unwrap(value)
      value.is_a?(Tensor) ? value.contents : value
    end

    def self.shape_of(value)
      value.is_a?(Tensor) ? value.shape : []
    end

    # Shapes align on trailing dimensions; missing leading dimensions act
    # as size 1. A dimension conflicts only when both sides are greater than
    # one and unequal. Ragged tensors participate on their outer axis.
    def self.broadcast_shape(*shapes)
      shapes = shapes.reject(&:empty?)
      return [] if shapes.empty?

      rank = shapes.map(&:length).max
      result = Array.new(rank, 1)

      shapes.each do |shape|
        offset = rank - shape.length
        shape.each_with_index do |dim, index|
          axis = offset + index
          target = result[axis]
          # An empty axis absorbs the result: 0 broadcasts against any
          # dimension and the aligned axis stays (or becomes) empty.
          if dim.zero? || target.zero?
            result[axis] = 0
            next
          end
          next if dim == 1

          if target != 1 && target != dim
            raise Dentaku::ShapeError.new(shapes, target, dim, axis)
          end
          result[axis] = dim
        end
      end

      result.freeze
    end

    # Materializes a broadcast of a wrapped value or scalar to shape.
    def self.broadcast(value, shape)
      return Tensor.unwrap(value) if shape.empty?

      if value.is_a?(Tensor)
        return value if value.shape == shape

        expanded = expand(value.contents, value.shape, shape)
        construct(expanded, shape, true)
      else
        expand_scalar(value, shape)
      end
    end

    def scalar?
      shape.empty?
    end

    def ragged?
      !@regular
    end

    def regular?
      @regular
    end

    def contents
      @value
    end
    alias to_a contents
    alias entries contents

    def length
      shape.first || 0
    end

    def [](index)
      @value[index]
    end

    # Row-major element count. Ragged tensors expose one position per outer
    # member.
    def position_count
      (ragged? ? [shape.first] : shape).reduce(1, :*)
    end

    # Leaf at a row-major position. Ragged members are returned raw and not
    # traversed, so irregular inner structure stays opaque.
    def position_value(position)
      return @value if scalar?
      return @value[position] if ragged?

      position_path(position).reduce(@value) { |node, index| node[index] }
    end

    def position_path(position)
      remainder = position
      path = []
      shape.reverse_each do |dim|
        remainder, index = remainder.divmod(dim)
        path.unshift(index)
      end
      path
    end

    # Builds a regular tensor from row-major leaves.
    def self.assemble(shape, leaves)
      return leaves.first if shape.empty?

      construct(reshape(leaves.dup, shape), shape, true)
    end

    def self.construct(value, shape, regular)
      allocate.tap do |instance|
        instance.instance_variable_set(:@shape, shape.map { |dim| Integer(dim) }.freeze)
        instance.instance_variable_set(:@value, value)
        instance.instance_variable_set(:@regular, regular)
        instance.freeze
      end
    end

    private

    def self.reshape(leaves, dims)
      return leaves.first if dims.empty?

      dim, *rest = dims
      group_size = rest.reduce(1, :*)
      Array.new(dim) { reshape(leaves.shift(group_size), rest) }
    end
    private_class_method :reshape

    def self.regular_shape(value)
      return nil if value.is_a?(Tensor)
      return [] unless value.is_a?(::Array)
      return [0] if value.empty?

      child_shapes = value.map { |child| regular_shape(child) }
      return nil if child_shapes.any?(&:nil?) || child_shapes.uniq.length > 1

      [value.length] + child_shapes.first
    end
    private_class_method :regular_shape

    def self.expand_scalar(value, shape)
      return new([], shape) if shape.any?(&:zero?)

      _dim, *rest = shape
      leaf = rest.empty? ? value : expand_scalar(value, rest).contents
      new(Array.new(shape.first, leaf), shape)
    end
    private_class_method :expand_scalar

    # Broadcasts a nested Ruby array from current_shape to target_shape.
    # Both shapes are aligned at their trailing edge; a missing leading axis
    # behaves like a size-one axis.
    def self.expand(value, current_shape, target_shape)
      return value if current_shape.empty? && target_shape.empty?

      target_dim = target_shape.first

      if current_shape.empty? || current_shape.length < target_shape.length
        # Value is a scalar or lacks this leading axis: wrap its broadcast
        # to the remaining axes, then repeat at this axis.
        inner = expand(value, current_shape, target_shape.drop(1))
        return Array.new(target_dim, inner)
      end

      current_dim = current_shape.first
      if current_dim == target_dim
        value.map { |child| expand(child, current_shape.drop(1), target_shape.drop(1)) }
      else
        # current_dim must be 1: broadcast the single child and repeat it.
        child = expand(value.first, current_shape.drop(1), target_shape.drop(1))
        Array.new(target_dim, child)
      end
    end
    private_class_method :expand
  end

  class ShapeError < BaseError
    attr_reader :shapes, :axis, :left_dimension, :right_dimension

    def initialize(shapes, left_dimension, right_dimension, axis)
      @shapes = shapes
      @axis = axis
      @left_dimension = left_dimension
      @right_dimension = right_dimension
      inspected = shapes.map(&:inspect).join(" and ")
      super("array shapes #{inspected} cannot be broadcast on axis #{axis} " \
            "(#{left_dimension} != #{right_dimension})")
    end
  end

  # One element-wise position failed while other positions succeeded. The
  # strict calculator raises BatchError wrapping these; the non-bang
  # calculator reports each failure to its block and returns nil for the
  # failed positions.
  class ElementError
    attr_reader :index_path, :cause_error

    def initialize(index_path, cause_error)
      @index_path = Array(index_path)
      @cause_error = cause_error
    end

    def message
      "error at array index #{@index_path.inspect}: #{@cause_error.message}"
    end
  end

  class BatchError < BaseError
    attr_reader :element_errors, :partial_results

    def initialize(element_errors, partial_results = nil)
      @element_errors = element_errors
      @partial_results = partial_results
      first = element_errors.first
      super(first ? first.message : "one or more array elements failed")
    end

    def index_errors
      element_errors.map { |error| [error.index_path, error.cause_error] }
    end
  end
end
