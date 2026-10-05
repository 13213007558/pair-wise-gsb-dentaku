module Dentaku
  module TypeCheck
    # union-find style unification over type terms. Every binding remembers
    # the constraint that caused it, so a failure can report the whole set
    # of mutually conflicting constraints.
    class Solver
      def initialize
        @bindings = {}
        @provenance = {}
        @next_id = 0
      end

      def fresh_var(label: nil, origin: nil)
        Var.new(@next_id += 1, label: label, origin: origin)
      end

      def fresh_dim(label: nil, origin: nil)
        DimVar.new(@next_id += 1, label: label, origin: origin)
      end

      def snapshot
        [@bindings.dup, @provenance.dup]
      end

      def restore(state)
        @bindings, @provenance = state
      end

      def resolve(term)
        case term
        when Var, DimVar
          bound = @bindings[term.key]
          bound ? resolve(bound) : term
        when ArrayType
          ArrayType.new(resolve(term.element), resolve(term.dim))
        else
          term
        end
      end

      def unify(left, right, constraint, ancestors = [])
        original_left, original_right = left, right
        left = resolve(left)
        right = resolve(right)

        return left if left.equal?(right)
        if left.is_a?(Var) || left.is_a?(DimVar)
          return bind(left, right, constraint)
        end
        return bind(right, left, constraint) if right.is_a?(Var) || right.is_a?(DimVar)
        return merge_unknown(left, right) if left.is_a?(Unknown) || right.is_a?(Unknown)

        unify_ground(left, right, original_left, original_right, constraint, ancestors)
      end

      # raise a Conflict for two irreconcilable terms, attaching the
      # constraint that failed plus every constraint that bound the
      # variables involved
      def conflict!(left, right, constraint, what = "type mismatch", ancestors: [])
        message = "#{what}: cannot reconcile #{render(left)} with #{render(right)}"
        constraints = ([constraint] + ([left, right] + ancestors).flat_map { |t| explain(t) }).uniq
        raise Conflict.new(message, constraints, node: constraint.node)
      end

      def render(term)
        case term = resolve(term)
        when ArrayType
          "array<#{render(term.element)}>[#{render(term.dim)}]"
        when DimConst
          term.value.to_s
        when Var, DimVar
          term.label ? term.label.to_s : "?"
        else
          term.to_s
        end
      end

      private

      def bind(var, term, constraint)
        conflict!(var, term, constraint, "recursive type") if occurs?(var, term)
        @bindings[var.key] = term
        @provenance[var.key] = constraint
        term
      end

      def occurs?(var, term)
        case term = resolve(term)
        when Var, DimVar then term.key == var.key
        when ArrayType then occurs?(var, term.element) || occurs?(var, term.dim)
        else false
        end
      end

      def unify_ground(left, right, original_left, original_right, constraint, ancestors)
        case left
        when Primitive
          conflict!(original_left, original_right, constraint, ancestors: ancestors) unless left == right
          left
        when DimConst
          unless right.is_a?(DimConst) && right.value == left.value
            conflict!(original_left, original_right, constraint, "dimension mismatch", ancestors: ancestors)
          end
          left
        when ArrayType
          conflict!(original_left, original_right, constraint, ancestors: ancestors) unless right.is_a?(ArrayType)
          deeper = ancestors + [original_left, original_right]
          element = unify(left.element, right.element, constraint, deeper)
          dim = unify(left.dim, right.dim, constraint, deeper)
          ArrayType.new(element, dim)
        else
          conflict!(original_left, original_right, constraint, ancestors: ancestors)
        end
      end

      def merge_unknown(left, right)
        notes = [left, right].select { |t| t.is_a?(Unknown) }.flat_map(&:notes).uniq
        Unknown.new(notes)
      end

      # constraints that produced the current bindings of the variables
      # inside a term, oldest first
      def explain(term, seen = {})
        constraints = []
        walk = lambda do |t|
          case t
          when Var, DimVar
            return if seen[t.key]
            seen[t.key] = true
            if (cause = @provenance[t.key])
              constraints << cause
              walk.call(@bindings[t.key])
            end
          when ArrayType
            walk.call(t.element)
            walk.call(t.dim)
          end
        end
        walk.call(term)
        constraints
      end
    end
  end
end
