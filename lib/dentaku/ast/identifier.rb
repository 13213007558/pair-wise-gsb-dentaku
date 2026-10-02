require_relative '../exceptions'
require 'dentaku/string_casing'
require 'dentaku/evaluation_session'

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
          session = context[EvaluationSession::CONTEXT_KEY]
          if session
            session.suspend_on(identifier)
          else
            raise UnboundVariableError.new([identifier]),
                  "no value provided for variables: #{identifier}"
          end
        end

        case v
        when Node
          resolve_dynamic_value(context) do
            value = v.value(context)
            context[identifier] = value if Dentaku.cache_identifier?
            value
          end
        when Proc
          resolve_dynamic_value(context) { v.call }
        else
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

      # Resolution of Node/Proc values can suspend (a stored formula that
      # itself references unbound variables) or fail (the callback raised).
      # Inside an EvaluationSession the produced value is memoized so
      # resuming never re-triggers the fetch, and failures are reported as
      # ResolutionError at this identifier.
      def resolve_dynamic_value(context)
        session = context[EvaluationSession::CONTEXT_KEY]
        cache = session.node_cache if session
        return cache[self] if cache && cache.key?(self)

        value = yield
        cache[self] = value if cache
        value
      rescue StandardError
        raise unless session
        session.resolution_failed(identifier)
      end

      def dependencies_of(node, context)
        node.respond_to?(:dependencies) ? node.dependencies(context) : []
      end
    end
  end
end
