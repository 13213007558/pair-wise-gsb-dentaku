require 'dentaku/dependency_resolver'
require 'dentaku/exceptions'
require 'dentaku/flat_hash'
require 'dentaku/parser'
require 'dentaku/simultaneous_solver'
require 'dentaku/tokenizer'

module Dentaku
  class BulkExpressionSolver
    class StrictEvaluator
      def initialize(calculator)
        @calculator = calculator
      end

      def evaluate(*args, &block)
        @calculator.evaluate!(*args, &block)
      end
    end

    class PermissiveEvaluator
      def initialize(calculator, block)
        @calculator = calculator
        @block = block || ->(*) { :undefined }
      end

      def evaluate(*args, &block)
        handler = block || ->(_expr, ex) { @block.call(ex) }
        @calculator.evaluate(*args, &handler)
      end
    end

    def initialize(expressions, calculator)
      @expression_hash = FlatHash.from_hash(expressions)
      @calculator = calculator
    end

    def solve!(simultaneous: false)
      @evaluator = StrictEvaluator.new(calculator)
      solve(simultaneous: simultaneous, &raise_exception_handler)
    end

    def solve(simultaneous: false, &block)
      @evaluator ||= PermissiveEvaluator.new(calculator, block)
      error_handler = block || return_undefined_handler
      results = load_results(simultaneous: simultaneous, &error_handler)

      return results if results.is_a?(Dentaku::SimultaneousSolution)

      FlatHash.expand(
        expression_hash.each_with_object({}) do |(k, v), r|
          default = v.nil? ? v : :undefined
          r[k] = results.fetch(k.to_s, default)
        end
      )
    end

    def dependencies
      Hash[expression_deps].tap do |d|
        d.values.each do |deps|
          unresolved = deps.reject { |ud| d.has_key?(ud) }
          unresolved.each { |u| add_dependencies(d, u) }
        end
      end
    end

    private

    def self.dependency_cache
      @dep_cache ||= {}
    end

    attr_reader :expression_hash, :calculator, :evaluator

    def return_undefined_handler
      ->(*) { :undefined }
    end

    def raise_exception_handler
      ->(ex) { raise ex }
    end

    def expression_with_exception_handler(var_name, &block)
      ->(_expr, ex) {
        ex.assigned_to = var_name
        block.call(ex)
      }
    end

    def load_results(simultaneous: false, &block)
      facts, _formulas = expressions.transform_keys { |k| normalized_name(k) }
                                    .transform_values { |v| calculator.ast(v) }
                                    .partition { |_, v| calculator.dependencies(v, nil).empty? }

      evaluated_facts = facts.to_h.each_with_object({}) do |(var_name, ast), h|
        with_rescues(var_name, h, block) do
          h[var_name] = ast.is_a?(Array) ? ast.map(&:value) : ast.value
        end
      end

      context = calculator.memory.merge(evaluated_facts)
      resolve_units = simultaneous ? simultaneous_units(context) : nil
      cyclic_members = simultaneous ? resolve_units.select(&:cyclic).flat_map(&:members) : []
      expressions_by_normalized_name = expressions.each_key.with_object({}) do |name, h|
        h[normalized_name(name)] = name
      end

      results = {}
      family_solutions = []
      ordered_keys = simultaneous ? units_in_order(resolve_units) : variables_in_resolve_order
      ordered_keys.each do |var_name|
        expression_key = simultaneous ? expressions_by_normalized_name[var_name] : var_name
        next if expressions[expression_key].nil?

        if cyclic_members.include?(var_name)
          unit = resolve_units.find { |u| u.members.include?(var_name) }
          next unless var_name == unit.trigger

          solution = solve_component(unit.members, context, results, &block)
          family_solutions << solution if solution&.family?
          next
        end

        with_rescues(var_name, results, block) do
          results[var_name] = evaluated_facts[normalized_name(var_name)] || evaluator.evaluate(
            expressions[expression_key],
            context.merge(results),
            &expression_with_exception_handler(var_name, &block)
          ).tap { |res|
            res.assigned_to = var_name if res.respond_to?(:assigned_to=)
            res
          }
        end
      end

      if family_solutions.length == 1
        family_solutions.first
      elsif family_solutions.any?
        merged_family_solution(family_solutions)
      else
        results
      end

    rescue TSort::Cyclic => ex
      block.call(ex)
      {}
    end

    ResolveUnit = Struct.new(:members, :cyclic) do
      def trigger
        members.last
      end

      def cyclic?
        cyclic
      end
    end

    # SCCs made only of keys being solved here. Cycles may run transitively
    # through formulas stored in calculator memory, so the key graph is built
    # from reachable expression keys, not just each formula's direct deps.
    def simultaneous_units(context)
      @key_dep_graph = dependency_graph_keys(context)
      graph = @key_dep_graph
      units = DependencyResolver.strongly_connected_components(graph, calculator.case_sensitive).map do |members|
        cyclic = members.length > 1 || graph.fetch(members.first, []).include?(members.first)
        ResolveUnit.new(members, cyclic)
      end
      expand_cyclic_units(units, context)
    end

    # Equations that depend on a ring's unknowns without feeding back into it
    # are part of the same linear problem (p = q + r where q = q, r = r is one
    # family). Merge cyclic SCCs with those dependent singletons via union-find.
    def expand_cyclic_units(units, _context)
      ring_units = units.select(&:cyclic)
      return units if ring_units.empty?

      trigger_of = {}
      units.each { |unit| unit.members.each { |member| trigger_of[member] = unit.trigger } }
      parent = units.each_with_object({}) { |unit, h| h[unit.trigger] = unit.trigger }
      find_root = lambda do |key|
        root = key
        root = parent[root] while parent[root] != root
        while parent[key] != root
          parent[key], key = root, parent[key]
        end
        root
      end
      union = lambda do |left, right|
        root_left = find_root.call(left)
        root_right = find_root.call(right)
        parent[root_right] = root_left unless root_left == root_right
      end

      cyclic_keys = ring_units.flat_map(&:members)
      # repeated passes close transitive connections (a singleton reaching two
      # rings joins them; singletons reaching the joined group join next pass)
      units.length.times do
        changed = false
        units.reject(&:cyclic).each do |unit|
          key = unit.trigger
          touched = @key_dep_graph.fetch(key, []) & cyclic_keys
          next if touched.empty?

          touched.each { |dep| union.call(key, trigger_of.fetch(dep, dep)) }
          unless cyclic_keys.include?(key)
            cyclic_keys << key
            changed = true
          end
        end
        break unless changed
      end

      units.group_by { |unit| find_root.call(unit.trigger) }.map do |_, grouped|
        keys = grouped.flat_map(&:members).uniq
        ResolveUnit.new(order_members(keys, grouped), grouped.any?(&:cyclic))
      end
    end

    # members of a merged unit contain a cycle, so plain topological sorting
    # is impossible. Put the cyclic SCC members first (in SCC order), followed
    # by the absorbed dependent equations in dependency order. The linear
    # solver treats every member as an unknown regardless of position.
    def order_members(keys, grouped)
      cyclic_keys = grouped.select(&:cyclic).flat_map(&:members)
      dependent = keys - cyclic_keys
      ordered = cyclic_keys.dup
      pending = dependent.dup
      until pending.empty?
        ready = pending.select { |key| (@key_dep_graph.fetch(key, []) & pending).empty? }
        ready = pending.dup if ready.empty?
        ready.each do |key|
          ordered << key
          pending.delete(key)
        end
      end
      ordered
    end

    # topological order over the SCC condensation, emitted as a flat key list
    # in which a cyclic unit's member keys precede its trigger (the last one)
    def units_in_order(units)
      graph = {} # representative => dependency representatives
      by_member = {}
      units.each do |unit|
        representative = unit.trigger
        unit.members.each { |member| by_member[member] = representative }
      end
      # recompute the key graph (already cached per call? no) -- use deps method
      units.each do |unit|
        representative = unit.trigger
        deps = unit.members.flat_map { |member| @key_dep_graph[member] || [] }.uniq
        graph[representative] = deps.map { |dep| by_member[dep] }.uniq.reject { |dep| dep == representative }
      end
      ordered = DependencyResolver.find_resolve_order(graph, calculator.case_sensitive)
      ordered.flat_map do |representative|
        unit = units.find { |u| u.trigger == representative }
        unit.cyclic? ? unit.members : [representative]
      end
    end

    def dependency_graph_keys(context)
      key_set = expressions.keys.map { |name| normalized_name(name) }
      expressions.each_key.with_object({}) do |var, graph|
        graph[normalized_name(var)] = reachable_keys(var, key_set, context)
      end
    end

    def reachable_keys(var, key_set, context)
      ast = calculator.ast(expressions[original_expression_key(var)])
      direct = calculator.dependencies(ast, context) | ast.dependencies(AST::Node::STATIC_CONTEXT)
      keys = direct.select { |dep| key_set.include?(dep) }
      queue = direct.reject { |dep| key_set.include?(dep) }
      seen = {}
      until queue.empty?
        dep = queue.shift
        next unless seen[dep].nil?
        seen[dep] = true

        node = context[dep]
        next unless node.respond_to?(:dependencies)

        node.dependencies(context).each do |transitive|
          if key_set.include?(transitive)
            keys << transitive
          else
            queue << transitive
          end
        end
      end
      keys.uniq
    end

    def solve_component(members, context, results, &block)
      equations = members.each_with_object({}) do |name, h|
        h[name] = calculator.ast(expressions[original_expression_key(name)])
      end

      solution = Dentaku::SimultaneousSolver.new(
        calculator, equations, context.merge(results)
      ).solve
      solution.to_h.each do |name, value|
        value.assigned_to = name if value.respond_to?(:assigned_to=)
        results[name] = value
      end
      solution
    rescue Dentaku::Error, TSort::Cyclic => ex
      members.each { |name| results[name] = block.call(ex) }
      nil
    end

    def original_expression_key(normalized)
      expressions.keys.find { |name| normalized_name(name) == normalized } || normalized
    end

    def merged_family_solution(solutions)
      values = solutions.each_with_object({}) { |solution, h| h.merge!(solution.values) }
      free = solutions.flat_map(&:free_variables)
      Dentaku::SimultaneousSolution.new(
        :family, values, free_variables: free, verified: solutions.all?(&:verified?)
      )
    end

    def with_rescues(var_name, results, block)
      yield
    rescue Dentaku::UnboundVariableError, Dentaku::ZeroDivisionError, Dentaku::ArgumentError => ex
      ex.assigned_to = var_name
      results[var_name] = block.call(ex)
    ensure
      stored_name = normalized_name(var_name)
      if results[var_name] == :undefined && calculator.memory.has_key?(stored_name)
        results[var_name] = calculator.memory[stored_name]
      end
    end

    # names are normalized the same way the calculator stores them, so that
    # facts and memory lookups line up with the identifiers the parser emits
    def normalized_name(variable_name)
      calculator.standardize_case(variable_name.to_s)
    end

    def expressions
      @expressions ||= Hash[expression_hash.map { |k, v| [k.to_s, v] }]
    end

    def expression_deps
      expressions.map do |var, expr|
        [var, calculator.dependencies(expr)]
      end
    end

    def add_dependencies(current_dependencies, variable)
      node = calculator.memory[variable]
      if node.respond_to?(:dependencies)
        current_dependencies[variable] = node.dependencies
        node.dependencies.each { |d| add_dependencies(current_dependencies, d) }
      end
    end

    def variables_in_resolve_order
      cache_key = "#{!!calculator.case_sensitive}|#{expressions.keys.map(&:to_s).sort.join("|")}"
      @ordered_deps ||= self.class.dependency_cache.fetch(cache_key) {
        DependencyResolver.find_resolve_order(dependencies, calculator.case_sensitive).tap do |d|
          self.class.dependency_cache[cache_key] = d if calculator.cache_dependency_order?
        end
      }
    end
  end
end
