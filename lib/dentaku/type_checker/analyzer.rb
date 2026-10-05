module Dentaku
  module TypeChecker
    # Walks one parsed formula, inferring its type and generating
    # constraints. Never calls Node#value and never executes function
    # implementations, so it is safe to run before any data exists.
    #
    # The env maps variable names to Types; the unifier is shared across
    # a batch of formulas so constraints from one formula constrain another.
    class Analyzer
      attr_reader :unknowns, :formula_name

      def initialize(unifier:, serial:, env: {}, signatures: {},
                     expression: nil, formula_name: nil)
        @unifier = unifier
        @serial = serial
        @env = env
        @signatures = signatures
        @expression = expression
        @formula_name = formula_name
        @unknowns = []
        @enum_scopes = []
      end

      # returns the inferred (unresolved) result type for the node
      def check(node)
        case node
        when AST::Nil
          Type.any(:null, node.source_range)
        when AST::Literal
          literal_type(node)
        when AST::Identifier
          identifier_type(node)
        when AST::Array
          array_literal_type(node)
        when AST::Grouping
          check(node.instance_variable_get(:@node))
        when AST::Negation
          operand = check(node.node)
          expect(operand, scalar(:numeric), node, "unary minus")
          scalar(:numeric)
        when AST::Percentage
          operand = check(node.left)
          expect(operand, scalar(:numeric), node, "percentage")
          scalar(:numeric)
        when AST::Arithmetic
          arithmetic_type(node)
        when AST::Comparator
          comparison_type(node)
        when AST::Combinator
          combinator_type(node)
        when AST::Bitwise
          left = check(node.left)
          right = check(node.right)
          expect(left, scalar(:numeric), node, "bitwise operand")
          expect(right, scalar(:numeric), node, "bitwise operand")
          scalar(:numeric)
        when AST::Access
          access_type(node)
        when AST::If
          if_type(node)
        when AST::Map, AST::Filter, AST::All, AST::Any
          enum_type(node)
        when AST::Reduce
          reduce_type(node)
        when AST::Pluck
          # PLUCK operates on arrays of hashes; hashes are not in the type
          # system yet, so the element type is unknown
          check(node.args[0])
          record_unknown(
            reason: "function 'pluck' reads hash fields, which have no declared type",
            name: 'pluck',
            range: node.source_range
          )
          Type.any(:untyped_function, node.source_range)
        when AST::Function
          function_type(node)
        when AST::CaseSwitchVariable
          check(node.instance_variable_get(:@node))
        when AST::CaseWhen
          check(node.instance_variable_get(:@node))
        when AST::CaseThen
          check(node.instance_variable_get(:@node))
        when AST::CaseElse
          check(node.instance_variable_get(:@node))
        when AST::CaseConditional
          check(node.then)
        when AST::Case
          case_type(node)
        else
          # nodes without a static rule contribute an unknown type
          Type.any(:unsupported_node, node.source_range)
        end
      end

      private

      def scalar(name)
        Type.scalar(name)
      end

      def use(node_or_range, label = nil)
        range = node_or_range.respond_to?(:source_range) ? node_or_range.source_range : node_or_range
        Use.new(range, label, @formula_name)
      end

      def expect(actual, expected, node, label)
        @unifier.unify(actual, expected, [use(node, label)])
      rescue TypeConflict => conflict
        raise conflict_with_sites(conflict, node, label)
      end

      def conflict_with_sites(conflict, node, label)
        sites = (conflict.sites + [use(node, label)]).uniq(&:key)
        TypeConflict.new(conflict.left, conflict.right, sites)
      end

      def literal_type(node)
        case node.type
        when :numeric then scalar(:numeric)
        when :logical then scalar(:logical)
        when :string then scalar(:string)
        when :datetime then scalar(:date)
        else Type.any(:literal, node.source_range)
        end
      end

      def identifier_type(node)
        name = node.identifier

        enum_binding = @enum_scopes.reverse_each.map { |scope| scope[name] }.compact.first
        return enum_binding if enum_binding

        if @env.key?(name)
          @env[name]
        else
          any = Type.any(:undeclared_variable, node.source_range)
          record_unknown(
            reason: "variable '#{name}' has no declared type",
            name: name,
            range: node.source_range
          )
          any
        end
      end

      def array_literal_type(node)
        elements = node.instance_variable_get(:@elements)
        return Type.array(Type.flex(@serial.next_id)) if elements.empty?

        element_var = Type.flex(@serial.next_id)
        elements.each do |element|
          type = check(element)
          @unifier.unify(element_var, type, [use(element, "array element")])
        end
        Type.array(element_var)
      rescue TypeConflict => conflict
        raise enrich_array_conflict(conflict, node)
      end

      def enrich_array_conflict(conflict, node)
        sites = (conflict.sites + [use(node, "array literal")]).uniq(&:key)
        TypeConflict.new(conflict.left, conflict.right, sites)
      end

      def arithmetic_type(node)
        left = check(node.left)
        right = check(node.right)

        # dates allow date +/- numeric(duration-like) arithmetic
        left_resolved = @unifier.resolve(left)
        if Type.date?(left_resolved)
          expect(right, scalar(:numeric), node.right, "date arithmetic operand")
          return scalar(:date)
        end

        expect(left, scalar(:numeric), node.left, "left operand of #{node.operator}")
        expect(right, scalar(:numeric), node.right, "right operand of #{node.operator}")
        scalar(:numeric)
      end

      def comparison_type(node)
        left = check(node.left)
        right = check(node.right)

        # comparisons require both sides to share a type; either one may
        # still be an unresolved variable
        @unifier.unify(left, right, [
          use(node.left, "left of #{node.display_operator}"),
          use(node.right, "right of #{node.display_operator}")
        ])
        scalar(:logical)
      rescue TypeConflict => conflict
        raise TypeConflict.new(conflict.left, conflict.right,
                              (conflict.sites + [use(node, node.display_operator.to_s)]).uniq(&:key))
      end

      def combinator_type(node)
        left = check(node.left)
        right = check(node.right)
        expect(left, scalar(:logical), node.left, "logical operand")
        expect(right, scalar(:logical), node.right, "logical operand")
        scalar(:logical)
      end

      def access_type(node)
        structure = check(node.structure)
        index = check(node.index)
        resolved = @unifier.resolve(structure)

        if Type.array?(resolved)
          expect(index, scalar(:numeric), node.index, "array index")
          resolved.element
        elsif Type.any?(resolved)
          # hashes/unknown structures: element type is unknown
          Type.any(resolved.source, node.source_range)
        else
          Type.any(:unsupported_structure, node.source_range)
        end
      end

      def if_type(node)
        predicate = check(node.predicate)
        expect(predicate, scalar(:logical), node.predicate, "IF condition")

        left = check(node.left)
        right = check(node.right)

        @unifier.unify(left, right, [
          use(node.left, "IF true branch"),
          use(node.right, "IF false branch")
        ])

        # the result follows whichever branch is concrete
        @unifier.resolve(left)
      rescue TypeConflict => conflict
        raise TypeConflict.new(conflict.left, conflict.right,
                              (conflict.sites + [use(node, "IF")]).uniq(&:key))
      end

      def enum_type(node)
        collection, item_identifier, expression = node.args
        collection_type = check(collection)
        element_var = Type.flex(@serial.next_id)
        expect(collection_type, Type.array(element_var), collection, "collection argument")

        result = with_enum_scope(item_identifier.identifier => element_var) do
          check(expression)
        end

        case node
        when AST::Map then Type.array(result)
        when AST::Filter
          expect(result, scalar(:logical), expression, "FILTER predicate")
          Type.array(element_var)
        when AST::All, AST::Any
          expect(result, scalar(:logical), expression, "predicate")
          scalar(:logical)
        end
      end

      def reduce_type(node)
        collection, memo_identifier, item_identifier, expression = node.args[0..3]
        initial = node.args[4]

        collection_type = check(collection)
        element_var = Type.flex(@serial.next_id)
        memo_var = Type.flex(@serial.next_id)
        expect(collection_type, Type.array(element_var), collection, "collection argument")
        expect(memo_var, check(initial), initial, "REDUCE initial value") if initial

        result = with_enum_scope(
          item_identifier.identifier => element_var,
          memo_identifier.identifier => memo_var
        ) do
          check(expression)
        end
        expect(result, memo_var, expression, "REDUCE expression")
        memo_var
      end

      def with_enum_scope(bindings)
        @enum_scopes.push(bindings)
        yield
      ensure
        @enum_scopes.pop
      end

      def function_type(node)
        name = function_name(node)
        signature = @signatures[name] || BuiltIn[name]
        return untyped_function(node, name) if signature.nil?

        params, result = signature.instantiate(@serial)
        arg_types = node.args.map { |arg| check(arg) }

        bind_parameters(node, name, signature, params, arg_types)
        result
      end

      def bind_parameters(node, name, signature, params, arg_types)
        if signature.variadic
          bind_variadic(node, name, params, arg_types)
        else
          min = params.length - signature.optional_count
          unless arg_types.length.between?(min, params.length)
            range = min == params.length ? params.length.to_s : "#{min}..#{params.length}"
            raise arity_conflict(node, name, range, arg_types.length)
          end

          arg_types.each_with_index do |arg_type, index|
            arg = node.args[index]
            @unifier.unify(arg_type, params[index], [
              use(arg, "argument #{index + 1} of #{name.upcase}")
            ])
          end
        end
      rescue TypeConflict => conflict
        raise TypeConflict.new(conflict.left, conflict.right,
                              (conflict.sites + [use(node, "#{name.upcase}() call")]).uniq(&:key))
      end

      def bind_variadic(node, name, params, arg_types)
        min = params.length - 1
        if arg_types.length < min
          raise arity_conflict(node, name, "at least #{min}", arg_types.length)
        end

        params.each_with_index do |param, index|
          next unless node.args[index]

          @unifier.unify(arg_types[index], param, [
            use(node.args[index], "argument #{index + 1} of #{name.upcase}")
          ])
        end

        rest_param = params.last
        node.args.each_with_index do |arg, index|
          next if index < min

          @unifier.unify(arg_types[index], rest_param, [
            use(arg, "argument #{index + 1} of #{name.upcase}")
          ])
        end
      end

      def arity_conflict(node, name, expected, actual)
        TypeConflict.new(
          Type.variable("arity(#{expected})"),
          Type.variable("arity(#{actual})"),
          [use(node, "#{name.upcase}() expects #{expected} argument(s), got #{actual}")]
        )
      end

      def untyped_function(node, name)
        node.args.each { |arg| check(arg) }
        record_unknown(
          reason: "function '#{name}' has no type signature",
          name: name,
          range: node.source_range
        )
        Type.any(:untyped_function, node.source_range)
      end

      def function_name(node)
        name = node.class.name || node.class.to_s
        name.to_s.split("::").last.to_s.downcase
      end

      def case_type(node)
        switch_type = check(node.switch)
        result_var = Type.flex(@serial.next_id)

        node.conditions.each do |condition|
          when_type = check(condition.when)
          then_type = check(condition.then)
          @unifier.unify(switch_type, when_type, [use(condition.when, "CASE WHEN")])
          @unifier.unify(result_var, then_type, [use(condition.then, "CASE THEN")])
        end

        if node.else
          else_type = check(node.else)
          @unifier.unify(result_var, else_type, [use(node.else, "CASE ELSE")])
        end

        result_var
      end

      def record_unknown(reason:, name:, range:)
        @unknowns << Unknown.new(
          reason: reason,
          name: name,
          range: range,
          sites: [],
          formula: @formula_name
        )
      end
    end
  end
end
