require "dentaku/ast"
require "dentaku/calculator"
require "dentaku/print_visitor"
require "dentaku/string_casing"

module Dentaku
  module TypeCheck
    # walks an expression's AST and unifies type constraints, producing
    # the result type or the set of mutually conflicting constraints
    class Checker
      include Dentaku::StringCasing

      # never called: only registered so signature-declared functions parse.
      # the nil return type keeps parse-time operand checks permissive
      STUB = ->(*) { nil }

      attr_reader :solver, :case_sensitive

      def initialize(variables: {}, functions: {}, calculator: nil, case_sensitive: false)
        @calculator = calculator || Dentaku::Calculator.new
        @case_sensitive = case_sensitive
        @solver = Solver.new
        @env = {}
        @signatures = {}
        @unknowns = []
        @inferred = {}
        @stack = []
        @current_formula = nil

        variables.each { |name, spec| declare_variable(name, spec) }
        functions.each do |name, spec|
          @signatures[standardize_case(name.to_s)] = Signature.parse(spec, name: name)
        end
        register_signature_stubs
      end

      def declare_variable(name, spec)
        key = standardize_case(name.to_s)
        var = solver.fresh_var(label: key)
        term = Signature.term(spec, solver, {}, {}, context: "declaration of `#{key}`")
        solver.unify(var, term, Constraint.new("`#{key}` is declared as #{solver.render(term)}"))
        @env[key] = var
      end

      # make a formula's result type available as a variable for the
      # formulas that follow it
      def bind_formula_result(name, term, node)
        key = standardize_case(name.to_s)
        var = solver.fresh_var(label: key)
        solver.unify(var, term, Constraint.new(
          "formula `#{key}` produces #{solver.render(term)}",
          node: node, formula: key
        ))
        @env[key] = var
      end

      def unknown_formula_term(name, node)
        note = UnknownNote.new(reason: :unresolved_formula, node: node, formula: name)
        @unknowns << note
        Unknown.new([note])
      end

      def check(expression, formula: nil)
        snapshot = solver.snapshot
        unknown_count = @unknowns.size
        inferred_keys = @inferred.keys
        @current_formula = formula
        node = expression.is_a?(Dentaku::AST::Node) ? expression : @calculator.ast(expression)
        term = visit(node)
        Result.new(
          term: term,
          solver: solver,
          node: node,
          unknowns: (@unknowns[unknown_count..] + notes_in(term)).uniq,
          inferred: inferred_since(inferred_keys)
        )
      rescue Conflict => conflict
        solver.restore(snapshot)
        Result.new(
          conflict: conflict,
          solver: solver,
          node: node,
          unknowns: @unknowns[unknown_count..] || [],
          inferred: inferred_since(inferred_keys)
        )
      ensure
        @current_formula = nil
      end

      private

      def register_signature_stubs
        @signatures.each_key do |name|
          next if @calculator.function_registry.get(name)

          @calculator.add_function(name, nil, STUB)
        end
      end

      def visit(node)
        case node
        when AST::DateTime then TypeCheck.primitive(:datetime)
        when AST::Numeric then TypeCheck.primitive(:numeric)
        when AST::Logical then TypeCheck.primitive(:logical)
        when AST::String then TypeCheck.primitive(:string)
        when AST::Nil then TypeCheck.primitive(:nil)
        when AST::Identifier then visit_identifier(node)
        when AST::Grouping then descend(node, [:grouped, 0]) { visit(node.node) }
        when AST::Negation, AST::Percentage then visit_unary_numeric(node)
        when AST::Addition, AST::Subtraction then visit_date_arithmetic(node)
        when AST::Arithmetic, AST::Bitwise then visit_numeric_operation(node)
        when AST::Comparator then visit_comparator(node)
        when AST::Combinator then visit_combinator(node)
        when AST::Access then visit_access(node)
        when AST::Array then visit_array(node)
        when AST::If then visit_if(node)
        when AST::Case then visit_case(node)
        when AST::CaseSwitchVariable, AST::CaseWhen, AST::CaseThen, AST::CaseElse
          visit(node.node)
        when AST::Function then visit_function(node)
        when AST::Literal
          primitive = TypeCheck.primitive_name(node.type)
          raise ::ArgumentError, "unsupported literal type #{node.type.inspect}" unless primitive

          TypeCheck.primitive(primitive)
        else
          raise ::ArgumentError, "type checking is not supported for #{node.class}"
        end
      end

      def visit_identifier(node)
        key = node.identifier
        @env.fetch(key) do
          var = solver.fresh_var(label: key, origin: "undeclared variable `#{key}`")
          @inferred[key] = var
          @env[key] = var
        end
      end

      def visit_unary_numeric(node)
        operand = node.is_a?(AST::Negation) ? node.node : node.left
        term = descend(node, [:operand, 0]) { visit(operand) }
        return term if unknown?(term)

        unify_numeric(term, node, "operand of `#{render(node)}`")
        TypeCheck.primitive(:numeric)
      end

      def visit_numeric_operation(node)
        left = descend(node, [:operand, :left]) { visit(node.left) }
        right = descend(node, [:operand, :right]) { visit(node.right) }
        return merge_unknown(left, right) if unknown?(left) || unknown?(right)

        unify_numeric(left, node, "left operand of `#{render(node)}`")
        unify_numeric(right, node, "right operand of `#{render(node)}`")
        TypeCheck.primitive(:numeric)
      end

      def visit_date_arithmetic(node)
        left = descend(node, [:operand, :left]) { visit(node.left) }
        right = descend(node, [:operand, :right]) { visit(node.right) }
        return merge_unknown(left, right) if unknown?(left) || unknown?(right)

        numeric = TypeCheck.primitive(:numeric)
        datetime = TypeCheck.primitive(:datetime)
        duration = TypeCheck.primitive(:duration)
        subtraction = node.is_a?(AST::Subtraction)

        if solver.resolve(left) == datetime
          if subtraction && solver.resolve(right) == datetime
            solver.unify(right, datetime, constraint(node, "right operand of `#{render(node)}`"))
            numeric
          else
            unify_one_of(right, [numeric, duration], node,
                         "right operand of `#{render(node)}` must be numeric or a duration")
            datetime
          end
        elsif solver.resolve(right) == datetime
          if subtraction
            solver.unify(left, datetime,
                         constraint(node, "left operand of `#{render(node)}` must be a date when subtracting dates"))
            numeric
          else
            unify_numeric(left, node, "left operand of `#{render(node)}`")
            datetime
          end
        else
          unify_numeric(left, node, "left operand of `#{render(node)}`")
          unify_numeric(right, node, "right operand of `#{render(node)}`")
          numeric
        end
      end

      def visit_comparator(node)
        left = descend(node, [:operand, :left]) { visit(node.left) }
        right = descend(node, [:operand, :right]) { visit(node.right) }
        return merge_unknown(left, right) if unknown?(left) || unknown?(right)

        solver.unify(left, right,
                     constraint(node, "operands of `#{render(node)}` must have the same type"))
        TypeCheck.primitive(:logical)
      end

      def visit_combinator(node)
        left = descend(node, [:operand, :left]) { visit(node.left) }
        right = descend(node, [:operand, :right]) { visit(node.right) }
        return merge_unknown(left, right) if unknown?(left) || unknown?(right)

        unify_logical(left, node, "left operand of `#{render(node)}`")
        unify_logical(right, node, "right operand of `#{render(node)}`")
        TypeCheck.primitive(:logical)
      end

      def visit_access(node)
        structure = descend(node, [:structure, 0]) { visit(node.structure) }
        index = descend(node, [:index, 0]) { visit(node.index) }
        return merge_unknown(structure, index) if unknown?(structure) || unknown?(index)

        resolved = solver.resolve(structure)
        if resolved.is_a?(ArrayType)
          unify_numeric(index, node, "index of `#{render(node)}`")
          return resolved.element
        end
        if resolved == TypeCheck.primitive(:string)
          unify_numeric(index, node, "index of `#{render(node)}`")
          return TypeCheck.primitive(:string)
        end
        if solver.resolve(index) == TypeCheck.primitive(:string)
          return unknown_for(node, reason: :hash_access)
        end

        element = solver.fresh_var(origin: "element of `#{render(node.structure)}`")
        solver.unify(structure, ArrayType.new(element, solver.fresh_dim),
                     constraint(node, "`#{render(node.structure)}` must be an array to be indexed"))
        unify_numeric(index, node, "index of `#{render(node)}`")
        element
      end

      def visit_array(node)
        element = node.elements.each_with_index.map do |el, i|
          descend(node, [:element, i]) { visit(el) }
        end.reduce do |acc, term|
          if unknown?(acc) || unknown?(term)
            merge_unknown(acc, term)
          else
            solver.unify(acc, term,
                         constraint(node, "elements of `#{render(node)}` must share a common type"))
          end
        end
        element ||= solver.fresh_var(origin: "element of `#{render(node)}`")
        ArrayType.new(element, DimConst.new(node.elements.length))
      end

      def visit_if(node)
        condition = descend(node, [:arg, 0]) { visit(node.predicate) }
        unify_logical(condition, node, "condition of `#{render(node)}`") unless unknown?(condition)
        left = descend(node, [:branch, 1]) { visit(node.left) }
        right = descend(node, [:branch, 2]) { visit(node.right) }
        return merge_unknown(condition, left, right) if unknown?(left) || unknown?(right)

        solver.unify(left, right,
                     constraint(node, "both branches of `#{render(node)}` must have a common type",
                                related: [node.left, node.right]))
      end

      def visit_case(node)
        switch = descend(node, [:switch, 0]) { visit(node.switch.node) }
        results = node.conditions.map do |condition|
          when_type = descend(condition, [:when, 0]) { visit(condition.when.node) }
          unless unknown?(switch) || unknown?(when_type)
            solver.unify(switch, when_type,
                         constraint(condition, "WHEN value of `#{render(condition)}` must match the CASE expression"))
          end
          descend(condition, [:branch, 1]) { visit(condition.then.node) }
        end
        results << descend(node, [:else, 0]) { visit(node.else.node) } if node.else
        results.reduce do |acc, term|
          if unknown?(acc) || unknown?(term)
            merge_unknown(acc, term)
          else
            solver.unify(acc, term,
                         constraint(node, "all branches of `#{render(node)}` must have a common type"))
          end
        end
      end
      def visit_function(node)
        name = node.name.to_s.downcase
        case name
        when "map", "filter", "all", "any" then visit_enum(node, name)
        when "reduce" then visit_reduce(node)
        when "pluck" then visit_pluck(node)
        when "sum", "avg" then visit_numeric_aggregate(node)
        when "min", "max" then visit_extremum(node)
        when "count" then visit_count(node)
        when "switch" then visit_switch(node)
        else visit_call(node, name)
        end
      end

      def visit_enum(node, kind)
        collection = descend(node, [:arg, 0]) { visit(node.args[0]) }
        item = solver.fresh_var(label: node.args[1].identifier,
                                origin: "element of `#{render(node.args[0])}`")
        dim = solver.fresh_dim(origin: "length of `#{render(node.args[0])}`")
        unless unknown?(collection)
          solver.unify(collection, ArrayType.new(item, dim),
                       constraint(node, "first argument of `#{render(node)}` must be an array"))
        end
        body = with_bindings(node.args[1].identifier => item) do
          descend(node, [:arg, 2]) { visit(node.args[2]) }
        end

        result =
          case kind
          when "map"
            ArrayType.new(body, dim)
          when "filter"
            unify_logical(body, node, "the expression of `#{render(node)}`") unless unknown?(body)
            ArrayType.new(item, solver.fresh_dim)
          else # all, any
            unify_logical(body, node, "the expression of `#{render(node)}`") unless unknown?(body)
            TypeCheck.primitive(:logical)
          end

        unknown?(collection) ? merge_unknown(collection, result) : result
      end

      def visit_reduce(node)
        collection = descend(node, [:arg, 0]) { visit(node.args[0]) }
        item = solver.fresh_var(label: node.args[2].identifier,
                                origin: "element of `#{render(node.args[0])}`")
        unless unknown?(collection)
          solver.unify(collection, ArrayType.new(item, solver.fresh_dim),
                       constraint(node, "first argument of `#{render(node)}` must be an array"))
        end
        memo = node.args[4] ? descend(node, [:arg, 4]) { visit(node.args[4]) } : item
        body = with_bindings(
          node.args[1].identifier => memo,
          node.args[2].identifier => item
        ) { descend(node, [:arg, 3]) { visit(node.args[3]) } }

        result =
          if unknown?(body) || unknown?(memo)
            merge_unknown(body, memo)
          else
            solver.unify(body, memo,
                         constraint(node, "the expression of `#{render(node)}` must produce the accumulator's type"))
          end
        unknown?(collection) ? merge_unknown(collection, result) : result
      end

      def visit_pluck(node)
        collection = descend(node, [:arg, 0]) { visit(node.args[0]) }
        dim = solver.fresh_dim
        unless unknown?(collection)
          solver.unify(collection, ArrayType.new(solver.fresh_var, dim),
                       constraint(node, "first argument of `#{render(node)}` must be an array"))
        end
        element =
          if node.args[2]
            descend(node, [:arg, 2]) { visit(node.args[2]) }
          else
            solver.fresh_var(origin: "values of `#{render(node)}`")
          end
        result = ArrayType.new(element, dim)
        unknown?(collection) ? merge_unknown(collection, result) : result
      end

      def visit_numeric_aggregate(node)
        terms = node.args.each_with_index.map do |arg, i|
          term = descend(node, [:arg, i]) { visit(arg) }
          next term if unknown?(term)

          resolved = solver.resolve(term)
          if resolved.is_a?(ArrayType)
            solver.unify(resolved.element, TypeCheck.primitive(:numeric),
                         constraint(node, "elements of the array in argument #{i + 1} of `#{render(node)}` must be numeric"))
          else
            unify_numeric(term, node, "argument #{i + 1} of `#{render(node)}`")
          end
          term
        end

        unknown_args = terms.select { |term| unknown?(term) }
        unknown_args.any? ? merge_unknown(*unknown_args) : TypeCheck.primitive(:numeric)
      end

      def visit_extremum(node)
        terms = node.args.each_with_index.map do |arg, i|
          term = descend(node, [:arg, i]) { visit(arg) }
          resolved = solver.resolve(term)
          resolved.is_a?(ArrayType) ? resolved.element : term
        end
        terms.reduce do |acc, term|
          if unknown?(acc) || unknown?(term)
            merge_unknown(acc, term)
          else
            solver.unify(acc, term,
                         constraint(node, "arguments of `#{render(node)}` must share a common type"))
          end
        end
      end

      def visit_count(node)
        node.args.each_with_index { |arg, i| descend(node, [:arg, i]) { visit(arg) } }
        TypeCheck.primitive(:numeric)
      end

      def visit_switch(node)
        raw = node.args
        value = descend(node, [:arg, 0]) { visit(raw[0]) }
        tail = raw[1..]
        default = tail.length.odd? ? tail[-1] : nil
        pairs = default ? tail[0..-2] : tail

        results = []
        pairs.each_slice(2).with_index do |(match, outcome), i|
          match_type = descend(node, [:arg, 1 + i * 2]) { visit(match) }
          unless unknown?(value) || unknown?(match_type)
            solver.unify(value, match_type,
                         constraint(node, "match ##{i + 1} of `#{render(node)}` must have the same type as the switched value"))
          end
          results << descend(node, [:arg, 2 + i * 2]) { visit(outcome) }
        end
        results << descend(node, [:arg, raw.length - 1]) { visit(default) } if default
        results.reduce do |acc, term|
          if unknown?(acc) || unknown?(term)
            merge_unknown(acc, term)
          else
            solver.unify(acc, term,
                         constraint(node, "all results of `#{render(node)}` must have a common type"))
          end
        end
      end

      def visit_call(node, name)
        signature = @signatures[name] || Builtins[name]
        unless signature
          node.args.each_with_index { |arg, i| descend(node, [:arg, i]) { visit(arg) } }
          return unknown_for(node, reason: :missing_signature, function_name: name)
        end

        params, rest, returns = signature.instantiate(solver)
        args = node.args
        if args.length < params.length || (rest.nil? && args.length > params.length)
          expected = rest ? "at least #{params.length}" : params.length.to_s
          raise Conflict.new(
            "wrong number of arguments for `#{name}` (expected #{expected}, got #{args.length})",
            [constraint(node, "`#{render(node)}` passes #{args.length} argument(s), but `#{name}` expects #{expected}")],
            node: node
          )
        end

        actuals = args.each_with_index.map do |arg, i|
          expected_type =
            if i < params.length
              params[i]
            elsif signature.rest == :any
              # :any in rest position accepts each argument independently
              solver.fresh_var(origin: "argument of `#{name}`")
            else
              rest
            end
          actual = descend(node, [:arg, i]) { visit(arg) }
          unless unknown?(actual)
            solver.unify(actual, expected_type, constraint(node, "argument #{i + 1} of `#{render(node)}`"))
          end
          actual
        end

        # an argument of unknown type makes the call's result unknown too:
        # the declared return type only holds if every argument checks out
        unknown_args = actuals.select { |actual| unknown?(actual) }
        unknown_args.any? ? merge_unknown(*unknown_args) : returns
      end

      def descend(node, role)
        @stack.push([node, role])
        yield
      ensure
        @stack.pop
      end

      def with_bindings(bindings)
        previous = bindings.keys.map { |key| [key, @env[key]] }
        bindings.each { |key, term| @env[key] = term }
        yield
      ensure
        previous.each do |key, term|
          term ? @env[key] = term : @env.delete(key)
        end
      end

      def constraint(node, description, related: [])
        Constraint.new(description, node: node, related: related, formula: @current_formula)
      end

      def unknown?(term)
        solver.resolve(term).is_a?(Unknown)
      end

      def merge_unknown(*terms)
        notes = terms.map { |term| solver.resolve(term) }
                     .select { |term| term.is_a?(Unknown) }
                     .flat_map(&:notes).uniq
        Unknown.new(notes)
      end

      def unknown_for(node, reason:, function_name: nil)
        note = UnknownNote.new(
          reason: reason, function_name: function_name,
          node: node, ancestors: @stack.dup, formula: @current_formula
        )
        @unknowns << note
        Unknown.new([note])
      end

      def unify_numeric(term, node, what)
        solver.unify(term, TypeCheck.primitive(:numeric), constraint(node, "#{what} must be numeric"))
      end

      def unify_logical(term, node, what)
        solver.unify(term, TypeCheck.primitive(:logical), constraint(node, "#{what} must be logical"))
      end

      def unify_one_of(term, options, node, what)
        resolved = solver.resolve(term)
        match = options.find { |option| option == resolved }
        return solver.unify(term, match, constraint(node, what)) if match
        if resolved.is_a?(Var)
          return solver.unify(term, options.first, constraint(node, what))
        end

        solver.conflict!(term, options.first, constraint(node, what))
      end

      def render(node)
        Constraint.render(node)
      end

      def notes_in(term)
        case term = solver.resolve(term)
        when Unknown then term.notes
        when ArrayType then notes_in(term.element)
        else []
        end
      end

      def inferred_since(keys)
        @inferred.reject { |key, _| keys.include?(key) }
      end
    end
  end
end
