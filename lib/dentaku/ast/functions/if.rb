require_relative '../function'
require_relative '../../vector'

module Dentaku
  module AST
    class If < Function
      attr_reader :predicate, :left, :right

      def self.min_param_count
        3
      end

      def self.max_param_count
        3
      end

      def initialize(predicate, left, right)
        @predicate = predicate
        @left      = left
        @right     = right
      end

      def args
        [predicate, left, right]
      end

      def value(context = {})
        if Dentaku::Vector.positioned?(context)
          condition = Dentaku::Vector.leaf(Dentaku::Tensor.wrap(predicate.value(context)), context)
          return condition ? left.value(context) : right.value(context)
        end

        condition = predicate.value(context)
        if condition.is_a?(::Array)
          vector_select(condition, context)
        elsif condition
          left.value(context)
        else
          right.value(context)
        end
      end

      def node_type
        :condition
      end

      def tensor_shape(context = {})
        # The output shape follows the predicate; branches broadcast into it.
        Dentaku::Vector.infer_shape(predicate, context)
      end

      def type
        left.type
      end

      def dependencies(context = {})
        return all_arg_dependencies(context) if static_mode?(context) || !predicate.pure?

        predicate.value(context) ? left.dependencies(context) : right.dependencies(context)
      rescue Dentaku::Error
        all_arg_dependencies(context)
      end

      private

      # Element-wise branch selection. Each position evaluates only its
      # selected branch through a positioned context, so a division by zero
      # or a side-effecting function on the unselected side never runs for
      # that position. The predicate anchors the batch along its own axes;
      # each selected position contributes that position's branch member,
      # which may itself be a nested array.
      def vector_select(condition, context)
        predicate_tensor = Dentaku::Tensor.wrap(condition)
        return select_ragged(condition, [], context) if predicate_tensor.ragged?

        output_shape = condition_shape(predicate_tensor)
        positions = predicate_tensor.position_count
        selected_values = ::Array.new(positions)
        errors = []

        positions.times do |position|
          selected = predicate_tensor.position_value(position)
          positioned = Dentaku::Vector.with_position(context, output_shape, position)
          branch = selected ? left : right
          begin
            value = branch.value(positioned)
            selected_values[position] = branch_member(value, output_shape, position)
          rescue Dentaku::Error => error
            index_path = Dentaku::Vector.path_for(output_shape, position)
            errors << Dentaku::ElementError.new(index_path, error)
            selected_values[position] = nil
          end
        end

        result = assemble_selection(predicate_tensor, output_shape, selected_values)
        raise Dentaku::BatchError.new(errors, result) if errors.any?

        result
      end

      # The predicate's regular shape anchors output positions. Ragged
      # predicates select by outer member.
      def condition_shape(predicate_tensor)
        predicate_tensor.shape
      end

      # Ragged predicate: recursively walk the irregular nested booleans.
      # At each leaf, the matching branch is evaluated under an explicit
      # index path so branch identifiers resolve to the same nested
      # position. Only the selected branch is reached, which keeps unchosen
      # side effects dormant and avoids unchosen division-by-zero leaves.
      def select_ragged(members, path, context)
        errors = []
        result = walk_ragged(members, path, context, errors)
        raise Dentaku::BatchError.new(errors, result) if errors.any?

        result
      end

      def walk_ragged(condition, path, context, errors)
        unless condition.is_a?(::Array)
          branch = condition ? left : right
          begin
            return branch.value(Dentaku::Vector.with_path(context, path))
          rescue Dentaku::Error => error
            errors << Dentaku::ElementError.new(path, error)
            return nil
          end
        end

        condition.each_with_index.map do |leaf, index|
          walk_ragged(leaf, path + [index], context, errors)
        end
      end

      def assemble_selection(predicate_tensor, output_shape, selected_values)
        return selected_values if predicate_tensor.ragged?

        Dentaku::Tensor.assemble(output_shape, selected_values).contents
      end

      # Selects one branch element by row-major position. Scalar branches
      # broadcast; regular branches yield the leaf aligned at this position
      # (standard trailing-axis broadcasting).
      def branch_member(value, output_shape, position)
        tensor = Dentaku::Tensor.wrap(value)
        return value unless tensor.is_a?(Dentaku::Tensor)
        return tensor.contents if tensor.scalar?

        path = Dentaku::Vector.path_for(output_shape, position)
        aligned_leaf(tensor, path)
      end

      def aligned_leaf(tensor, path)
        offset = path.length - tensor.shape.length
        coordinates = tensor.shape.each_with_index.map do |dim, index|
          dim == 1 ? 0 : path[offset + index]
        end
        coordinates.reduce(tensor.contents) { |node, index| node[index] }
      end

      def all_arg_dependencies(context)
        args.flat_map { |arg| arg.dependencies(context) }.uniq
      end
    end
  end
end

Dentaku::AST::Function.register_class(:if, Dentaku::AST::If)
