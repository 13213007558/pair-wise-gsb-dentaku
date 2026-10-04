require_relative './operation'
require_relative './vectorizable'
require 'dentaku/exceptions'

module Dentaku
  module AST
    class Combinator < Operation
      include Vectorizable

      def initialize(*)
        super

        unless valid_node?(left)
          raise NodeError.new(:logical, left.type, :left),
                "#{self.class} requires logical operands"
        end
        unless valid_node?(right)
          raise NodeError.new(:logical, right.type, :right),
                "#{self.class} requires logical operands"
        end
      end

      def type
        :logical
      end

      def dependencies(context = {})
        return super if static_mode?(context)

        left_deps = left.dependencies(context)
        right_deps = right.dependencies(context)
        return [] if left_deps.empty? && left.pure? && decisive?(left.value(context))
        return [] if right_deps.empty? && right.pure? && decisive?(right.value(context))

        (left_deps + right_deps).uniq
      rescue Dentaku::Error
        super
      end

      def value(context = {})
        left_value = begin
          left.value(context)
        rescue UnboundVariableError => unbound
          unbound
        end

        if Dentaku::Vector.positioned?(context)
          combine(left_value, right.value(context))
        elsif left_value.is_a?(::Array)
          vector_combine(left_value, context)
        elsif !left_value.is_a?(UnboundVariableError) && decisive?(left_value)
          left_value
        else
          right_value = right.value(context)
          if right_value.is_a?(::Array)
            vector_combine_mixed(left_value, right_value, context)
          else
            combine(left_value, right_value)
          end
        end
      end

      private

      # static dependency check: this runs at parse time, and evaluating
      # short-circuit guards here would execute user functions (#197)
      def valid_node?(node)
        node && (node.dependencies(Node::STATIC_CONTEXT).any? || node.type == :logical)
      end

      # whether a single operand with this value already determines the
      # result, regardless of the other operand
      def decisive?(operand_value)
        raise NotImplementedError
      end

      def combine(lhs, rhs)
        unless lhs.is_a?(UnboundVariableError)
          return lhs if decisive?(lhs)
          return rhs
        end

        # The left operand is unbound; the right operand can still decide
        # the result on its own. If it does not, the left value was needed.
        raise lhs unless decisive?(rhs)

        rhs
      end

      # An array left operand drives evaluation: a decisive left leaf never
      # evaluates the right subtree at that position. The right side is read
      # through a positioned context only when needed.
      def vector_combine(left_value, context)
        Dentaku::Vector.elementwise([left_value], context) do |(lhs), positioned|
          next lhs if !lhs.is_a?(UnboundVariableError) && decisive?(lhs)

          combine(lhs, right.value(positioned))
        end
      end

      # Scalar (or unbound) left with an array right.
      def vector_combine_mixed(left_value, right_value, context)
        Dentaku::Vector.elementwise([left_value, right_value], context) do |args, _positioned|
          combine(*args)
        end
      end
    end

    class And < Combinator
      def operator
        :and
      end

      private

      def decisive?(operand_value)
        !operand_value
      end
    end

    class Or < Combinator
      def operator
        :or
      end

      private

      def decisive?(operand_value)
        !!operand_value
      end
    end
  end
end
