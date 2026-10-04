module Dentaku
  module AST
    class Node
      # reserved context key (double-underscore prefix, like
      # __evaluation_mode) that switches dependencies() into static mode:
      # guards are never evaluated and every branch is reported
      STATIC_MODE_KEY = "__static_dependencies".freeze
      STATIC_CONTEXT = { STATIC_MODE_KEY => true }.freeze

      def self.precedence
        0
      end

      def self.arity
        nil
      end

      def self.resolve_class(*)
        self
      end

      def dependencies(context = {})
        []
      end

      def source_token
        nil
      end

      def child_nodes
        []
      end

      def source_range
        ranges = [source_token&.source_range] + (child_nodes || []).map(&:source_range)
        ranges.compact!
        return nil if ranges.empty?

        start = ranges.min_by(&:start_offset).start_pos
        finish = ranges.max_by(&:end_offset).end_pos
        Dentaku::SourceRange.new(start, finish)
      end

      # whether this subtree may be evaluated during dependency resolution
      # without running volatile user code; a property of the parsed AST,
      # computed once and memoized
      def pure?
        return @pure if defined?(@pure)

        @pure = compute_pure?
      end

      def type
        nil
      end

      def name
        self.class.name.to_s.split("::").last.upcase
      end

      private

      def static_mode?(context)
        context[STATIC_MODE_KEY] == true
      end

      def compute_pure?
        true
      end
    end
  end
end
