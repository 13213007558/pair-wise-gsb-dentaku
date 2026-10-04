require_relative '../exceptions'
require 'dentaku/string_casing'

module Dentaku
  module AST
    class Identifier < Node
      include StringCasing
      attr_reader :identifier, :case_sensitive

      def initialize(token, options = {})
        @case_sensitive = options.fetch(:case_sensitive, false)
        @identifier = standardize_case(token.value)
      end

      def value(context = {})
        v = context.fetch(identifier) do
          raise UnboundVariableError.new([identifier]),
                "no value provided for variables: #{identifier}"
        end

        resolved = case v
        when Node
          value = v.value(context)
          context[identifier] = value if Dentaku.cache_identifier?
          value
        when Proc
          v.call
        else
          v
        end

        Dentaku::Vector.positioned?(context) ? Dentaku::Vector.leaf(Dentaku::Tensor.wrap(resolved), context) : resolved
      end

      def dependencies(context = {})
        context.key?(identifier) ? dependencies_of(context[identifier], context) : [identifier]
      end

      def accept(visitor)
        visitor.visit_identifier(self)
      end

      def tensor_shape(context = {})
        value = context[identifier]
        return [] if value.is_a?(Proc)
        return value.tensor_shape(context) if value.is_a?(Node)
        Dentaku::Tensor.shape_of(Dentaku::Tensor.wrap(value))
      end

      def to_s
        identifier.to_s
      end

      private

      def dependencies_of(node, context)
        node.respond_to?(:dependencies) ? node.dependencies(context) : []
      end
    end
  end
end
