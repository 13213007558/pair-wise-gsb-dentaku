module Dentaku
  module TypeCheck
    # a declared function signature: parameter types, an optional rest
    # parameter type, and a return type. Named type variables are shared
    # within one call but instantiated fresh for every call site, so two
    # calls to the same polymorphic function never interfere.
    #
    # type specs:
    #   :numeric / :logical / :string / :datetime / :duration / :nil
    #   :any                       a fresh unconstrained variable
    #   any other symbol (:a)      a named type variable
    #   [:array, spec]             array with a fresh dimension variable
    #   [:array, spec, 3]          array with a fixed dimension
    #   [:array, spec, :n]         array with a named dimension variable
    class Signature
      attr_reader :params, :rest, :returns, :name

      def self.parse(spec, name: nil)
        unless spec.is_a?(Hash) && spec.key?(:returns)
          raise ::ArgumentError,
                "signature for `#{name}` must be a Hash like " \
                "{ params: [...], returns: :numeric }"
        end

        new(spec.fetch(:params, []), spec[:rest], spec[:returns], name: name)
      end

      def initialize(params, rest, returns, name: nil)
        @params = params
        @rest = rest
        @returns = returns
        @name = name
      end

      # fresh terms for one call site
      def instantiate(solver)
        vars = {}
        dims = {}
        context = name ? "parameter of `#{name}`" : nil
        [
          params.map { |p| Signature.term(p, solver, vars, dims, context: context) },
          rest && Signature.term(rest, solver, vars, dims, context: context),
          Signature.term(returns, solver, vars, dims, context: context)
        ]
      end

      def self.term(spec, solver, vars = {}, dims = {}, context: nil)
        case spec
        when Primitive, ArrayType, Var, DimVar, DimConst, Unknown
          spec
        when ::Symbol
          if (primitive = TypeCheck.primitive_name(spec))
            TypeCheck.primitive(primitive)
          elsif spec == :any
            solver.fresh_var(origin: context)
          else
            vars[spec] ||= solver.fresh_var(label: spec, origin: context)
          end
        when ::Array
          unless spec.first == :array && (2..3).cover?(spec.length)
            raise ::ArgumentError, "invalid type spec: #{spec.inspect}"
          end

          element = term(spec[1], solver, vars, dims, context: context)
          dim =
            case spec[2]
            when nil then solver.fresh_dim(origin: context)
            when ::Integer then DimConst.new(spec[2])
            when ::Symbol then dims[spec[2]] ||= solver.fresh_dim(label: spec[2], origin: context)
            else raise ::ArgumentError, "invalid array dimension: #{spec[2].inspect}"
            end
          ArrayType.new(element, dim)
        when ::Hash
          if spec.key?(:array)
            term([:array, spec[:array], spec[:dim]], solver, vars, dims, context: context)
          else
            raise ::ArgumentError, "invalid type spec: #{spec.inspect}"
          end
        else
          raise ::ArgumentError, "invalid type spec: #{spec.inspect}"
        end
      end
    end
  end
end
