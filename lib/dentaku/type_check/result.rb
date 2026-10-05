module Dentaku
  module TypeCheck
    # the outcome of statically checking one expression
    class Result
      attr_reader :node, :conflicts, :unknowns, :term

      def initialize(term: nil, conflict: nil, solver:, node:, unknowns: [], inferred: {})
        @term = term
        @solver = solver
        @node = node
        @conflicts = conflict ? [conflict] : []
        @unknowns = unknowns
        @inferred = inferred
      end

      def ok?
        conflicts.empty?
      end

      def conflict
        conflicts.first
      end

      # the resolved result type, or nil when checking failed
      def type
        @term && @solver.resolve(@term)
      end

      def unknown?
        type.is_a?(Unknown)
      end

      # plain-data rendering of the result type, e.g. :numeric or
      # [:array, :string, 3]; :unknown where the type cannot be determined
      def type_spec
        Result.spec(type)
      end

      # types inferred for identifiers that were not declared
      def variables
        @inferred.transform_values { |var| Result.spec(@solver.resolve(var)) }
      end

      def to_s
        if ok?
          unknown? ? "unknown (#{unknowns.map(&:message).join('; ')})" : @solver.render(@term)
        else
          conflict.message
        end
      end

      def self.spec(term)
        case term
        when nil then nil
        when Primitive then term.name
        when ArrayType
          dim = term.dim
          dim.is_a?(DimConst) ? [:array, spec(term.element), dim.value] : [:array, spec(term.element)]
        when Var then term.label ? term.label.to_sym : :unknown
        when DimConst then term.value
        when DimVar then term.label ? term.label.to_sym : :unknown
        when Unknown then :unknown
        else term
        end
      end
    end
  end
end
