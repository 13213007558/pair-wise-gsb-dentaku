require_relative '../exceptions'
require 'fiber'
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
        return resumable_value(context) if resumable?(context)

        v = context.fetch(identifier) do
          raise UnboundVariableError.new([identifier]),
                "no value provided for variables: #{identifier}"
        end

        case v
        when Node
          value = v.value(context)
          context[identifier] = value if Dentaku.cache_identifier?
          value
        when Proc
          v.call
        else
          v
        end
      end

      def resumable_value(context)
        Fiber.yield(identifier) unless context.key?(identifier)

        value = context.fetch(identifier)

        case value
        when Node
          resolved = value.value(context)
          context[identifier] = resolved if Dentaku.cache_identifier?
          resolved
        when Proc
          begin
            value.call
          rescue StandardError => error
            raise VariableResolutionError.new(identifier, error, self)
          end
        else
          value
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

      def resumable?(context)
        context.key?(Dentaku::CalculationSession::SESSION_KEY)
      end

      def side_effect?(context = nil)
        context&.key?(identifier) && context[identifier].is_a?(Proc)
      end

      def dependencies_of(node, context)
        node.respond_to?(:dependencies) ? node.dependencies(context) : []
      end
    end
  end
end
