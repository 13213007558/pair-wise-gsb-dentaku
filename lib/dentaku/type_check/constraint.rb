require "dentaku/exceptions"
require "dentaku/print_visitor"

module Dentaku
  module TypeCheck
    # a single "these two types must be equal" requirement, carrying enough
    # provenance to point back into the source expression
    class Constraint
      attr_reader :description, :node, :related, :formula

      def initialize(description, node: nil, related: [], formula: nil)
        @description = description
        @node = node
        @related = related
        @formula = formula
      end

      # character offset of the node in its expression, when known
      def position
        node && node.source_location
      end

      # offsets of the node plus any related nodes (e.g. both IF branches)
      def positions
        ([node] + related).compact.map(&:source_location).compact
      end

      def source
        node && Constraint.render(node)
      end

      def to_s
        parts = []
        parts << "in formula `#{formula}`" if formula
        parts << description
        parts << "at position #{position}" if position
        parts.join(", ")
      end

      def self.render(node)
        Dentaku::PrintVisitor.new(node).to_s
      rescue StandardError
        node.class.name
      end
    end

    # raised when constraints cannot all hold; carries the set of mutually
    # conflicting constraints that explain the failure
    class Conflict < Dentaku::BaseError
      attr_reader :constraints, :node

      def initialize(message, constraints, node: nil)
        @constraints = constraints
        @node = node
        super(message)
      end

      def position
        node && node.source_location
      end
    end

    # explains why some part of the expression has an unknown type and how
    # far that unknownness reaches
    class UnknownNote
      attr_reader :reason, :function_name, :node, :ancestors, :formula

      def initialize(reason:, node:, function_name: nil, ancestors: [], formula: nil)
        @reason = reason
        @function_name = function_name
        @node = node
        @ancestors = ancestors
        @formula = formula
      end

      def position
        node && node.source_location
      end

      def source
        node && Constraint.render(node)
      end

      # the chain of expressions the unknown value flows into, innermost
      # first, ending at the outermost affected expression
      def impact
        chain = ancestors.reverse.map { |(parent, role)| describe(parent, role) }
        chain << "the whole expression"
        chain
      end

      def message
        lines = [explanation]
        lines << "unknown propagates to: #{impact.join(' -> ')}"
        lines.join(" ")
      end
      alias_method :to_s, :message

      private

      def explanation
        case reason
        when :missing_signature
          "function `#{function_name}` has no declared signature, so its " \
          "result type is unknown (functions are never executed to guess types)"
        when :hash_access
          "the type of `#{source}` cannot be determined statically (hash access)"
        when :unresolved_formula
          "the result type of formula `#{formula}` is unknown because the " \
          "formula has a type conflict"
        else
          "the type of `#{source}` is unknown"
        end
      end

      def describe(parent, role)
        src = Constraint.render(parent)
        kind, value = role
        case kind
        when :arg then "argument #{value + 1} of `#{src}`"
        when :operand then "#{value} operand of `#{src}`"
        when :element then "element #{value + 1} of `#{src}`"
        when :branch then "a branch of `#{src}`"
        else "`#{src}`"
        end
      end
    end
  end
end
