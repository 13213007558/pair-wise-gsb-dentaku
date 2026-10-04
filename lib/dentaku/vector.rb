# frozen_string_literal: true

require_relative "tensor"

module Dentaku
  # Context keys carrying the active element-wise position. When present,
  # tensor identifiers return the scalar leaf for that position, which lets
  # IF evaluate only the selected branch element and keeps masked or
  # unselected work lazy.
  POSITION_KEY = :__vector_position
  POSITION_SHAPE_KEY = :__vector_shape
  # Explicit nested index path used by ragged IF selection.
  POSITION_PATH_KEY = :__vector_position_path

  # Element-wise evaluation engine.
  #
  # Operations resolve their operands (scalars or Ruby arrays coming from
  # variables), then hand them to this module. Scalars broadcast against
  # any shape; arrays align on their trailing dimensions. The scalar block
  # is invoked once per position with (operands, positioned_context) and
  # performs the actual operation or function call.
  module Vector
    module_function

    def positioned?(context)
      context.key?(POSITION_KEY) || context.key?(POSITION_PATH_KEY)
    end

    def with_position(context, shape, position)
      context.merge(POSITION_KEY => position, POSITION_SHAPE_KEY => shape)
    end

    # Resolves a value at the current position. Tensors broadcast against
    # the anchor shape and yield a scalar leaf; scalars pass through and a
    # positioned array literal yields the element at this position.
    def leaf(value, context)
      return value unless value.is_a?(Tensor)
      return value.contents if value.scalar?

      return ragged_leaf(value, context[POSITION_PATH_KEY]) if context.key?(POSITION_PATH_KEY)

      position = context[POSITION_KEY]
      anchor = context[POSITION_SHAPE_KEY]
      return value.position_value(position) if value.ragged?

      path = path_for(anchor, position)
      offset = anchor.length - value.shape.length
      coordinates = value.shape.each_with_index.map do |dim, index|
        dim == 1 ? 0 : path[offset + index]
      end
      coordinates.reduce(value.contents) { |node, index| node[index] }
    end

    # Resolves a ragged tensor member along an explicit index path. A path
    # that runs past the regular prefix indexes the raw nested arrays, so
    # irregular siblings stay reachable. A scalar (non-array) encountered
    # before the path ends broadcasts to every remaining level.
    def ragged_leaf(tensor, path)
      node = tensor.contents
      path.each do |index|
        return node unless node.is_a?(::Array)

        node = node.length == 1 ? node[0] : node[index]
      end
      node
    end

    def with_path(context, path)
      context.merge(POSITION_PATH_KEY => path)
    end

    def path_for(shape, position)
      remainder = position
      shape.reverse_each.with_object([]) do |dim, path|
        remainder, coordinate = remainder.divmod(dim)
        path.unshift(coordinate)
      end
    end

    # Element-wise evaluation. Returns a Ruby Array when any operand is an
    # array, otherwise the scalar result.
    #
    # Raises ShapeError before invoking the block when shapes conflict. A
    # Dentaku::Error raised at one position is collected with its index
    # (ElementError); other positions still produce values and the outer
    # call raises BatchError carrying the partial results.
    def elementwise(values, context, &block)
      wrapped = values.map { |value| Tensor.wrap(value) }
      shape = Tensor.broadcast_shape(*wrapped.map { |tensor| Tensor.shape_of(tensor) })
      return block.call(wrapped.map { |tensor| Tensor.unwrap(tensor) }, context) if shape.empty?

      if wrapped.any? { |tensor| tensor.is_a?(Tensor) && tensor.ragged? }
        ragged(wrapped, shape, context, &block)
      else
        regular(wrapped, shape, context, &block)
      end
    end

    # Infers the output shape of an AST node without evaluating it or any
    # side-effecting function. Returns [] for scalars/unknown nodes and an
    # array shape for expressions that statically produce a batch.
    def infer_shape(node, context)
      return [] unless node.respond_to?(:tensor_shape)

      node.tensor_shape(context)
    end

    # Element-wise evaluation driven by AST argument nodes. Each position
    # evaluates its arguments through a positioned context, so argument
    # side effects fire only for positions that need them. The caller has
    # already validated `shape` without evaluating anything.
    def elementwise_ast(arg_nodes, shape, context, &block)
      return ragged_ast(arg_nodes, shape, context, block, []) if static_ragged?(arg_nodes, context)

      total = shape.reduce(1, :*)
      leaves = Array.new(total)
      errors = []

      total.times do |position|
        positioned = with_position(context, shape, position)
        begin
          values = arg_nodes.map { |node| node.value(positioned) }
          leaves[position] = block.call(values, positioned)
        rescue Dentaku::Error => error
          errors << ElementError.new(path_for(shape, position), error)
          leaves[position] = nil
        end
      end

      finalize(Tensor.assemble(shape, leaves).contents, errors, context)
    end

    # Ragged evaluation: outer members line up position-wise, and irregular
    # inner arrays stay opaque. Each argument is evaluated once per outer
    # position through a positioned context; array members then combine
    # recursively while scalars broadcast.
    def ragged_ast(arg_nodes, outer_shape, context, block, index_path)
      outer = outer_shape.first
      members = Array.new(outer)
      errors = []

      outer.times do |index|
        positioned = with_position(context, outer_shape, index)
        begin
          values = arg_nodes.map { |node| node.value(positioned) }
          members[index] = combine_ragged(values, block)
        rescue Dentaku::Error => error
          errors << ElementError.new(index_path + [index], error)
          members[index] = nil
        end
      end

      finalize(members, errors, context)
    end

    # True when a batch argument is a ragged nested array. Only arguments
    # whose root value is statically available (identifiers/literals) are
    # inspected; computed expressions are assumed regular.
    def static_ragged?(arg_nodes, context)
      arg_nodes.any? do |node|
        value = static_value(node, context)
        next false unless value.is_a?(::Array)

        shape = node.tensor_shape(context)
        next true if shape.length > 1 && !consistent_shape?(value, shape)

        nested_ragged?(value)
      end
    end

    def static_value(node, context)
      return nil unless node.is_a?(Dentaku::AST::Identifier)

      value = context[node.identifier]
      value.is_a?(Dentaku::AST::Node) ? nil : value
    end

    def nested_ragged?(value)
      return false unless value.is_a?(::Array)
      return false if value.empty?

      children = value.select { |child| child.is_a?(::Array) }
      return false if children.empty?
      return true if children.length != value.length
      return true if children.map(&:length).uniq.length > 1

      value.any? { |child| nested_ragged?(child) }
    end

    def consistent_shape?(value, shape)
      return true if shape.empty?
      return false unless value.is_a?(::Array) && value.length == shape.first

      value.all? { |child| consistent_shape?(child, shape.drop(1)) }
    end

    # Recursively combines ragged members: arrays of equal length combine
    # element-wise; an array and a scalar broadcasts the scalar; two arrays
    # whose lengths disagree at an inner level stay as the left member (the
    # outer alignment is ragged by construction).
    def combine_ragged(values, block)
      arrays = values.select { |value| value.is_a?(::Array) }
      return block.call(values) if arrays.empty?

      length = arrays.map(&:length).max
      Array.new(length) do |index|
        child_values = values.map { |value| member_or_scalar(value, index) }
        combine_ragged(child_values, block)
      end
    end

    def member_or_scalar(value, index)
      return value unless value.is_a?(::Array)
      return value[0] if value.length == 1 && value.first.is_a?(::Array) == false

      value.fetch(index, value.length == 1 ? value[0] : nil)
    end

    def regular(wrapped, shape, context, &block)
      broadcasts = wrapped.map { |tensor| Tensor.broadcast(tensor, shape) }
      total = shape.reduce(1, :*)
      leaves = Array.new(total)
      errors = []

      total.times do |position|
        args = broadcasts.map { |tensor| tensor.position_value(position) }
        positioned = with_position(context, shape, position)
        begin
          leaves[position] = block.call(args, positioned)
        rescue Dentaku::Error => error
          errors << ElementError.new(path_for(shape, position), error)
          leaves[position] = nil
        end
      end

      finalize(Tensor.assemble(shape, leaves).contents, errors, context)
    end

    # Ragged evaluation runs per outer member. Regular operands share the
    # outer axis (already validated) and are indexed by member; scalars and
    # size-one axes broadcast. Irregular members are passed to the scalar
    # block as raw Ruby arrays and stay opaque to shape handling.
    def ragged(wrapped, shape, context, &block)
      outer = shape.first
      members = Array.new(outer)
      errors = []

      outer.times do |index|
        args = wrapped.map { |tensor| member(tensor, index) }
        positioned = with_position(context, shape, index)
        begin
          members[index] = block.call(args, positioned)
        rescue Dentaku::Error => error
          errors << ElementError.new([index], error)
          members[index] = nil
        end
      end

      finalize(members, errors, context)
    end

    def member(tensor, index)
      return tensor.contents if tensor.scalar?

      tensor.contents[index]
    end

    def finalize(results, errors, context)
      if errors.any? && context.key?(POSITION_KEY)
        # Nested inside another vectorized node: surface this position's
        # failure so the outer node records the full index path.
        raise errors.first.cause_error
      end

      raise BatchError.new(errors, results) if errors.any?

      results
    end
  end
end
