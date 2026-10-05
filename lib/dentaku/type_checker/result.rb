module Dentaku
  module TypeChecker
    # Outcome of statically checking one expression or a batch of formulas.
    #
    #   ok?       -- no contradictory constraints
    #   type      -- resolved result type of the (last/named) expression
    #   types     -- name => resolved type for a batch of formulas
    #   conflicts -- contradictory constraint sets with source positions
    #   unknowns  -- places that remain unknown and why they matter
    class Result
      attr_reader :type, :types, :conflicts, :unknowns, :expression

      def initialize(type: nil, types: {}, conflicts: [], unknowns: [], expression: nil)
        @type = type
        @types = types
        @conflicts = conflicts
        @unknowns = unknowns
        @expression = expression
      end

      def ok?
        conflicts.empty?
      end

      def fully_known?
        ok? && unknowns.empty?
      end

      def to_h
        h = { ok: ok?, type: rendered_type, conflicts: conflicts.map(&:message) }
        h[:types] = types.transform_values { |t| Renderer.render(t) } unless types.empty?
        h[:unknowns] = unknowns.map(&:reason) unless unknowns.empty?
        h
      end

      def rendered_type
        type && Renderer.render(type)
      end
    end
  end
end
