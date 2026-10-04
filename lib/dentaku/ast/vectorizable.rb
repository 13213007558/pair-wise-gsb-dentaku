# frozen_string_literal: true

require_relative "../vector"

module Dentaku
  module AST
    # Shared entry point for nodes whose scalar evaluation broadcasts over
    # array operands. `values` are already-resolved operands; the block
    # performs scalar work and is invoked once per aligned position.
    module Vectorizable
      private

      # Binary operation entry point. Shapes are inferred structurally
      # (without evaluating either operand), so a shape conflict raises
      # before either side -- which may contain side-effecting functions --
      # runs. At each position the operands are evaluated through a
      # positioned context.
      def vectorize_binary(left_node, right_node, context)
        if Dentaku::Vector.positioned?(context)
          return yield(left_node.value(context), right_node.value(context))
        end

        left_shape = Dentaku::Vector.infer_shape(left_node, context)
        right_shape = Dentaku::Vector.infer_shape(right_node, context)
        shape = Dentaku::Tensor.broadcast_shape(left_shape, right_shape)
        return yield(left_node.value(context), right_node.value(context)) if shape.empty?

        Dentaku::Vector.elementwise_ast([left_node, right_node], shape, context) do |values|
          yield(*values)
        end
      end
    end
  end
end
