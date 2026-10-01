require_relative '../exceptions'
require 'dentaku/string_casing'

module Dentaku
  module AST
    class Identifier < Node
      include StringCasing
      attr_reader :identifier, :case_sensitive, :line, :column

      def initialize(token, options = {})
        @case_sensitive = options.fetch(:case_sensitive, false)
        @identifier = standardize_case(token.value)
        @line = token.line
        @column = token.column
        @quoted = token.raw_value.to_s.start_with?('`')
      end

      def quoted?
        @quoted
      end

      def path_segments
        quoted? ? [identifier] : identifier.split('.')
      end

      def path_start_with?(other_identifier)
        segments = path_segments
        other_segments = other_identifier.path_segments
        segments.first(other_segments.length) == other_segments
      end

      def value(context = {})
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

      def dependencies(context = {})
        return [] if local_binding?(context)
        context.key?(identifier) ? dependencies_of(context[identifier], context) : [identifier]
      end

      def accept(visitor)
        visitor.visit_identifier(self)
      end

      def to_s
        identifier.to_s
      end

      private

      def dependencies_of(node, context)
        node.respond_to?(:dependencies) ? node.dependencies(context) : []
      end

      def local_binding?(context)
        Array(context[Node::LOCAL_SCOPE_KEY]).any? do |binding|
          path_start_with?(binding) || binding.path_start_with?(self)
        end
      end
    end
  end
end
