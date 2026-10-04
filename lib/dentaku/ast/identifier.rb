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
        tracker = context[EvaluationTracker::CONTEXT_KEY]
        v = context.fetch(identifier) do
          raise UnboundVariableError.new([identifier]),
                "no value provided for variables: #{identifier}"
        end

        case v
        when Node
          evaluate_node(v, context, tracker)
        when Proc
          tracker&.read(identifier)
          v.call
        else
          tracker&.read(identifier)
          v
        end
      end

      def dependencies(context = {})
        context.key?(identifier) ? dependencies_of(context[identifier], context) : [identifier]
      end

      def accept(visitor)
        visitor.visit_identifier(self)
      end

      def to_s
        identifier.to_s
      end

      private

      def evaluate_node(node, context, tracker)
        if tracker
          node.value(context)
        else
          value = node.value(context)
          context[identifier] = value if Dentaku.cache_identifier?
          value
        end
      end

      def dependencies_of(node, context)
        node.respond_to?(:dependencies) ? node.dependencies(context) : []
      end
    end
  end
end
