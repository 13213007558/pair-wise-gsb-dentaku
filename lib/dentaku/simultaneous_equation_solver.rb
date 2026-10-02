require 'bigdecimal'
require 'set'
require 'tsort'
require 'dentaku/affine_expression'
require 'dentaku/affine_expression_builder'
require 'dentaku/exceptions'
require 'dentaku/flat_hash'

module Dentaku
  class SimultaneousEquationSolver
    class Solution
      STATUSES = [:unique, :no_solution, :free_parameter_solution].freeze

      attr_reader :status, :solution, :free_variables

      def initialize(status, solution, free_variables = [], name_map = {})
        raise ::ArgumentError unless STATUSES.include?(status)

        @status = status
        @solution = solution
        @free_variables = free_variables
        @name_map = name_map
      end

      def unique?
        status == :unique
      end

      def no_solution?
        status == :no_solution
      end

      def free_parameter_solution?
        status == :free_parameter_solution
      end
      alias_method :family?, :free_parameter_solution?

      def verified?
        status != :no_solution
      end

      def values(bindings = {})
        raise Dentaku::BaseError, 'solution has no values' unless free_parameter_solution?

        name_map = @name_map.merge(free_variables.each_with_object({}) { |name, map| map[name] = name.to_s })
        normalized_bindings = bindings.each_with_object({}) do |(name, value), h|
          normalized_name = name_map.fetch(name, name.to_s.downcase)
          h[normalized_name] = AffineExpression.exact(value)
        end

        solution.each_with_object({}) do |(name, expression), h|
          value = expression.substitute(normalized_bindings)
          h[name] = value.constant? ? SimultaneousEquationSolver.output_number(value.constant) : value
        end
      end
    end

    class ComponentGraph
      include TSort

      def initialize(dependencies)
        @dependencies = dependencies
      end

      def components
        each_strongly_connected_component.to_a
      end

      def tsort_each_node(&block)
        @dependencies.each_key(&block)
      end

      def tsort_each_child(node, &block)
        @dependencies.fetch(node, []).each(&block)
      end
    end

    def self.output_number(value)
      value = value.to_r
      return value.to_i if value.denominator == 1
      return BigDecimal(value.numerator) / value.denominator if finite_decimal?(value)

      value
    end

    def self.finite_decimal?(value)
      denominator = value.denominator
      denominator /= 2 while denominator.even?
      denominator /= 5 while denominator % 5 == 0
      denominator == 1
    end

    def initialize(expressions, calculator, strict: false)
      @calculator = calculator
      @expression_hash = FlatHash.from_hash(expressions)
      @asts = {}
      @original_names = {}
      @context = calculator.memory.dup
      @cyclic_nodes = Set.new
      @strict = strict
    end

    def solve!(&block)
      solve(&block)
    end

    def solve(&block)
      expressions.each { |name, expression| ast(name, expression) }

      results = {}
      inconsistent = false

      components.each do |component|
        if cyclic?(component)
          component.each { |name| @cyclic_nodes.add(name) }
          component_result = solve_component(component, results)
          if component_result == :no_solution
            inconsistent = true
          else
            results.merge!(component_result)
          end
        else
          next if inconsistent && depends_on_unsolved_cycle?(component.first, results)

          evaluate_singleton(component.first, results)
        end
      end

      build_solution(results, inconsistent)
    rescue Dentaku::Error => ex
      raise if @strict

      block ? block.call(ex) : :undefined
    end

    private

    attr_reader :calculator, :expression_hash, :asts, :original_names, :context

    def expressions
      @expressions ||= expression_hash.each_with_object({}) do |(name, expression), h|
        normalized = normalize(name)
        h[normalized] = expression
        original_names[normalized] = name
      end
    end

    def normalize(name)
      calculator.standardize_case(name.to_s)
    end

    def ast(name, expression)
      asts[name] ||= calculator.ast(expression)
    end

    def target_names
      @target_names ||= expressions.keys
    end

    def graph
      @graph ||= begin
        graph = {}
        discover_graph_nodes(target_names, graph)
        graph.keys.each { |name| populate_graph_node(name, graph) }
        graph
      end
    end

    def discover_graph_nodes(names, graph)
      names.each do |name|
        next if graph.key?(name)

        graph[name] = nil
        node = graph_node(name)
        identifiers = if node.is_a?(::Array)
          node.flat_map { |child| static_identifiers(child) }
        else
          static_identifiers(node)
        end
        helper_names = identifiers.select { |dependency| context[dependency].is_a?(AST::Node) }
        discover_graph_nodes(helper_names, graph)
      end
    end

    def populate_graph_node(name, graph)
      return if graph[name]

      node = graph_node(name)
      identifiers = node.is_a?(::Array) ? node.flat_map { |child| static_identifiers(child) } : static_identifiers(node)
      dependencies = []

      identifiers.uniq.each do |dependency|
        next unless target_names.include?(dependency) || context[dependency].is_a?(AST::Node)

        dependencies << dependency
      end

      graph[name] = dependencies.uniq
    end

    def components
      ComponentGraph.new(graph).components
    end

    def cyclic?(component)
      component.length > 1 || graph.fetch(component.first, []).include?(component.first)
    end

    def graph_node(name)
      expressions.key?(name) ? asts.fetch(name) : context.fetch(name)
    end

    def static_identifiers(node)
      node.dependencies(AST::Node::STATIC_CONTEXT).map { |name| normalize(name) }
    end

    def evaluate_singleton(name, results)
      return unless expressions.key?(name)

      node = asts.fetch(name)
      value_context = context.merge(results)

      results[name] =
        if depends_on_affine?(node, value_context)
          with_nonlinear_location(name) do
            AffineExpressionBuilder.new(value_context).build(node)
          end
        elsif node.is_a?(::Array)
          node.map { |child| child.value(value_context) }
        else
          node.value(value_context)
        end
    rescue Dentaku::Error => ex
      ex.assigned_to = original_names.fetch(name, name)
      raise
    end

    def depends_on_affine?(node, value_context)
      dependencies = if node.is_a?(::Array)
        node.flat_map { |child| static_identifiers(child) }
      else
        static_identifiers(node)
      end
      dependencies.any? { |dependency| value_context[dependency].is_a?(AffineExpression) }
    end

    def depends_on_unsolved_cycle?(name, results)
      graph.fetch(name, []).any? do |dependency|
        !results.key?(dependency) && (target_names.include?(dependency) || context[dependency].is_a?(AST::Node))
      end
    end

    def solve_component(component, previous_results)
      equations = {}

      component.each do |name|
        node = equation_node(name)
        with_nonlinear_location(name) do
          equations[name] = AffineExpressionBuilder
            .new(context.merge(previous_results), component)
            .build(node)
        end
      end

      reduced = solve_linear_equations(component, equations)
      return :no_solution if reduced == :no_solution

      verify_component(equations, reduced)
      reduced
    end

    def equation_node(name)
      node = if expressions.key?(name)
        asts.fetch(name)
      else
        context.fetch(name)
      end

      unless node.is_a?(AST::Node)
        raise NonlinearEquationError.new(original_names.fetch(name, name))
      end

      node
    end

    def with_nonlinear_location(name)
      yield
    rescue NonlinearExpressionError
      formula = expressions[name]
      error = NonlinearEquationError.new(formula.is_a?(::String) ? formula : original_names.fetch(name, name))
      error.assigned_to = original_names.fetch(name, name)
      raise error
    rescue Dentaku::Error => ex
      ex.assigned_to = original_names.fetch(name, name)
      raise
    end

    def solve_linear_equations(variables, equations)
      matrix = variables.map do |name|
        equation = equations.fetch(name)
        row = variables.map { |variable| -equation.coefficients.fetch(variable, 0) }
        row[variables.index(name)] += 1
        row << equation.constant
        row
      end

      reduced = rref(matrix)
      return :no_solution if reduced.any? { |row| row[0...-1].all?(&:zero?) && !row.last.zero? }

      pivot_columns = reduced.filter_map do |row|
        coefficients = row[0...-1]
        pivot = coefficients.index { |value| !value.zero? }
        pivot if pivot && coefficients[pivot] == 1
      end
      free_columns = (0...variables.length).to_a - pivot_columns
      free_names = free_columns.map { |index| variables[index] }

      result = free_names.to_h { |name| [name, AffineExpression.variable(name)] }

      reduced.each do |row|
        pivot = row[0...-1].index { |value| !value.zero? }
        next unless pivot

        coefficients = free_columns.to_h do |column|
          value = row[column]
          value.zero? ? nil : [variables[column], -value]
        end.compact

        result[variables[pivot]] = AffineExpression.new(coefficients, row.last)
      end

      result
    end

    def rref(matrix)
      rows = matrix.map(&:dup)
      pivot_row = 0

      (0...rows.first.length - 1).each do |column|
        candidate = (pivot_row...rows.length).find { |row| !rows[row][column].zero? }
        next unless candidate

        rows[pivot_row], rows[candidate] = rows[candidate], rows[pivot_row]
        pivot_value = rows[pivot_row][column]
        rows[pivot_row] = rows[pivot_row].map { |value| value / pivot_value }

        rows.each_with_index do |row, index|
          next if index == pivot_row

          factor = row[column]
          rows[index] = row.each_with_index.map { |value, row_column| value - factor * rows[pivot_row][row_column] }
        end

        pivot_row += 1
      end

      rows
    end

    def verify_component(equations, solution)
      equations.each do |name, right_side|
        left_side = AffineExpression.variable(name)
        substituted_left = left_side.substitute(solution)
        substituted_right = right_side.substitute(solution)

        next if substituted_left == substituted_right

        raise Dentaku::BaseError, 'simultaneous solution failed verification for %s' % name
      end
    end

    def build_solution(results, inconsistent)
      return Solution.new(:no_solution, {}) if inconsistent

      target_solution = target_names.each_with_object({}) do |name, h|
        next unless expressions.key?(name)

        value = results.fetch(name)
        h[original_names.fetch(name)] = final_value(value)
      end

      expanded = FlatHash.expand(target_solution)
      free_variable_names = results.values.grep(AffineExpression).flat_map(&:variables).uniq
      free_variables = free_variable_names.map { |name| original_names.fetch(name, name.to_sym) }
      status = free_variables.empty? ? :unique : :free_parameter_solution

      solution = Solution.new(status, expanded, free_variables, name_to_normalized(target_solution))
      verify_solution(solution, target_solution, results) ? solution : Solution.new(:no_solution, {})
    end

    def final_value(value)
      return value if value.is_a?(::Array)
      return value unless value.is_a?(AffineExpression)

      value.constant? ? self.class.output_number(value.constant) : value
    end

    def verify_solution(solution, target_solution, results)
      substitution_context = context.merge(results).merge(normalized_target_solution(target_solution))

      target_names.all? do |name|
        node = asts.fetch(name)
        expected = target_solution.fetch(original_names.fetch(name))
        uses_affine_result = @cyclic_nodes.include?(name) || depends_on_affine?(node, substitution_context)
        actual = if solution.free_parameter_solution? || uses_affine_result
          AffineExpressionBuilder.new(substitution_context).build(node)
        elsif node.is_a?(::Array)
          node.map { |child| child.value(substitution_context) }
        else
          node.value(substitution_context)
        end

        equivalent_solution?(actual, expected)
      end
    rescue Dentaku::Error, NonlinearExpressionError
      false
    end

    def normalized_target_solution(target_solution)
      target_solution.each_with_object({}) do |(name, value), h|
        h[normalize(name)] = value
      end
    end

    def name_to_normalized(target_solution)
      target_solution.keys.each_with_object({}) do |name, map|
        map[name] = normalize(name)
      end
    end

    def equivalent_solution?(actual, expected)
      actual_affine = actual.is_a?(AffineExpression) ? actual : AffineExpression.cast(actual)
      expected_affine = expected.is_a?(AffineExpression) ? expected : AffineExpression.cast(expected)
      actual_affine == expected_affine
    rescue NonlinearExpressionError
      actual == expected
    end
  end
end
