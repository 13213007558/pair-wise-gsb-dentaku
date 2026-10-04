require 'set'
require 'dentaku/circular_dependency_error'
require 'dentaku/evaluation_tracker'
require 'dentaku/flat_hash'

module Dentaku
  class CalculationSession
    attr_reader :calculator, :last_changes

    def initialize(calculator = nil, formulas: {}, inputs: {})
      @calculator = calculator || Calculator.new
      @inputs = {}
      @formulas = {}
      @formula_keys = {}
      @cells = {}
      @dependents = Hash.new { |dependents, name| dependents[name] = Set.new }
      @function_version = current_function_version
      @last_changes = {}
      @evaluation_stack = []
      @pending_roots = Set.new

      load_formulas(formulas)
      store(inputs)
      evaluate(all_formula_names)
    end

    def store(values)
      @pending_roots ||= Set.new
      flatten_inputs(values).each do |name, value|
        next if @inputs.key?(name) && @inputs[name] == value

        @inputs[name] = value
        @pending_roots << name
      end

      self
    end
    alias_method :bind, :store

    def update(values = {})
      store(values)
      evaluate
    end

    def store_formula(name, expression)
      changed_roots = replace_formula(normalized_name(name), expression, name)
      evaluate(changed_roots)
      self
    end

    def formulas=(formulas)
      incoming = flatten_formulas(formulas)
      changed_roots = []

      (@formulas.keys - incoming.keys).each do |name|
        changed_roots.concat(remove_formula(name))
      end

      incoming.each do |name, expression|
        changed_roots.concat(replace_formula(name, expression, name))
      end

      evaluate(changed_roots)
    end

    def delete(name)
      normalized = normalized_name(name)
      changed_roots = @inputs.keys.select do |key|
        key == normalized || key.start_with?("#{normalized}.")
      end

      changed_roots.each { |key| @inputs.delete(key) }
      evaluate(changed_roots)
    end
    alias_method :delete_variable, :delete

    def delete_formula(name)
      changed_roots = remove_formula(normalized_name(name))
      evaluate(changed_roots)
    end

    def evaluate(additional_roots = [])
      roots = Set.new(additional_roots)
      roots.merge(@pending_roots)
      @pending_roots = Set.new

      if function_version_changed?
        @cells.each_value do |cell|
          cell.delete(:ast)
          cell[:evaluated] = false
          cell[:evaluating] = false
        end
        roots.merge(all_formula_names)
      end

      @cells.each_value { |cell| cell[:evaluating] = false }
      @cells.each do |name, cell|
        roots << name if cell[:volatile]
      end

      roots.each { |name| mark_dirty(name) if @formulas.key?(name) }

      queue = roots.to_a
      queued = Set.new(queue)
      evaluated = Set.new
      @changes = {}
      @queue = queue
      @queued = queued
      @evaluation_stack = []

      until queue.empty?
        name = queue.shift
        queued.delete(name)
        unless @formulas.key?(name)
          enqueue_dependents(name)
          next
        end
        next if evaluated.include?(name)

        stale_volatile = cell!(name)[:dependencies].any? do |dependency|
          @cells[dependency]&.dig(:volatile) &&
            roots.include?(dependency) &&
            !evaluated.include?(dependency)
        end

        if stale_volatile
          queue << name
          next
        end

        changed = evaluate_cell(name)
        evaluated << name
        next unless changed

        @changes[name] = cell_result(name)
        enqueue_dependents(name)
      end

      @last_changes = expand_results(@changes)
    ensure
      @changes = nil
      @queue = nil
      @queued = nil
    end
    alias_method :run, :evaluate
    alias_method :recalculate, :evaluate

    def results
      values = @formulas.keys.each_with_object({}) do |name, result|
        result[name] = cell_result(name)
      end
      expand_results(values)
    end
    alias_method :outputs, :results
    alias_method :to_h, :results

    def dependencies(name = nil)
      if name.nil?
        @cells.transform_values { |cell| cell[:dependencies].to_a }
      else
        cell!(name)[:dependencies].to_a
      end
    end

    def errors
      @cells.each_with_object({}) do |(name, cell), errors|
        errors[name] = cell[:error] if cell[:error]
      end
    end

    private

    def load_formulas(formulas)
      flatten_formulas(formulas).each do |name, expression|
        @formulas[name] = expression
        @formula_keys[name] = name
        @cells[name] = new_cell
      end
    end

    def replace_formula(name, expression, original_key)
      changed_roots = []

      unless @formulas[name] == expression
        changed_roots << name
        changed_roots.concat(dependents_of(name).to_a)
        detach(name)
        @formulas[name] = expression
        @formula_keys[name] = original_key
        @cells[name] = new_cell
      end

      changed_roots
    end

    def remove_formula(name)
      changed_roots = dependents_of(name).to_a
      changed_roots << name
      detach(name)
      @formulas.delete(name)
      @formula_keys.delete(name)
      @cells.delete(name)
      changed_roots
    end

    def dependents_of(name)
      cell = @cells[name]
      cell ? cell[:dependencies].flat_map { |dependency| @dependents[dependency] } : @dependents[name]
    end

    def detach(name)
      cell = @cells[name]
      return unless cell

      cell[:dependencies].each do |dependency|
        @dependents[dependency].delete(name)
      end
    end

    def evaluate_cell(name, shared_tracker = nil)
      cell = cell!(name)
      return false if cell[:evaluated]

      if cell[:evaluating]
        raise CircularDependencyError.new(@evaluation_stack + [name])
      end

      previous = {
        evaluated: cell[:evaluated],
        result: cell[:result],
        error: cell[:error]
      }
      cell[:evaluating] = true
      @evaluation_stack << name
      tracker = shared_tracker || EvaluationTracker.new

      begin
        ast = parse(name, cell)
        context = evaluation_context(tracker)
        result = evaluate_ast(ast, context)
        update_cell(cell, name, result: result, error: nil, tracker: tracker)
      rescue Dentaku::Error => error
        propagated = error_for(error, name)
        update_cell(cell, name, result: :undefined, error: propagated, tracker: tracker)
      ensure
        @evaluation_stack.pop
        cell[:evaluating] = false
      end

      changed = changed?(previous, cell)
      @changes[name] = cell[:result] if changed
      changed
    end

    def evaluate_ast(ast, context)
      if ast.is_a?(Array)
        return ast.map do |node|
          node.value(context)
        rescue Dentaku::Error
          :undefined
        end
      end

      ast.value(context)
    end

    def enqueue_dependents(name)
      @dependents[name].each do |dependent|
        cell = @cells[dependent]
        next if cell && cell[:evaluating]
        next if @queued.include?(dependent)

        @queue << dependent
        @queued << dependent
        mark_dirty(dependent)
        @evaluated&.delete(dependent)
      end
    end

    def mark_dirty(name)
      cell = @cells[name]
      cell[:evaluated] = false if cell && !cell[:evaluating]
    end

    def update_cell(cell, name, result:, error:, tracker:)
      new_dependencies = tracker.dependencies.to_set

      cell[:dependencies].each do |dependency|
        @dependents[dependency].delete(name) unless new_dependencies.include?(dependency)
      end

      new_dependencies.each do |dependency|
        @dependents[dependency] << name
      end

      cell[:result] = result
      cell[:error] = error
      cell[:dependencies] = new_dependencies
      cell[:volatile] = tracker.volatile
      cell[:evaluated] = true
    end

    def changed?(previous, cell)
      !previous[:evaluated] ||
        previous[:result] != cell[:result] ||
        !same_error?(previous[:error], cell[:error])
    end

    def same_error?(left, right)
      return left.nil? == right.nil? if left.nil? || right.nil?

      left.class == right.class && left.message == right.message
    end

    def parse(name, cell)
      return cell[:ast] if cell.key?(:ast)

      expression = @formulas.fetch(name)
      cell[:ast] = if expression.is_a?(AST::Node)
                     expression
                   else
                     @calculator.disable_cache { @calculator.ast(expression) }
                   end
    rescue Dentaku::Error
      cell.delete(:ast)
      raise
    end

    def evaluation_context(tracker)
      context = @inputs.merge(
        :__evaluation_mode => :permissive,
        EvaluationTracker::KEY => tracker
      )

      @formulas.each_key do |name|
        context[name] = ->(*_args) { resolve_formula(name, tracker) }
      end

      context
    end

    def resolve_formula(name, parent_tracker = nil)
      cell = @cells.fetch(name)
      dependent_tracker = EvaluationTracker.new
      evaluated_inline = false
      changed = false
      if cell[:evaluated]
        raise CircularDependencyError.new(@evaluation_stack + [name]) if active_cycle?(name)
      else
        evaluated_inline = true
        changed = evaluate_cell(name, dependent_tracker)
      end
      parent_tracker.add_dependency(name)
      parent_tracker.function_volatile! if parent_tracker && cell[:volatile]
      begin
        raise error_for(cell[:error], name) if cell[:error]

        cell[:result]
      ensure
        enqueue_dependents(name) if evaluated_inline && changed
      end
    end

    def active_cycle?(name, visited = Set.new)
      return false unless visited.add?(name)

      dependencies = @cells[name]&.dig(:dependencies) || Set.new
      return true if dependencies.any? { |dependency| @evaluation_stack.include?(dependency) }

      dependencies.any? { |dependency| @formulas.key?(dependency) && active_cycle?(dependency, visited) }
    end

    def error_for(error, name)
      propagated = error.dup rescue error
      propagated.assigned_to = name if propagated.respond_to?(:assigned_to=)
      propagated
    end

    def cell_result(name)
      cell!(name)[:result]
    end

    def cell!(name)
      @cells.fetch(normalized_name(name))
    end

    def new_cell
      {
        result: :undefined,
        error: nil,
        dependencies: Set.new,
        volatile: false,
        evaluated: false,
        evaluating: false
      }
    end

    def expand_results(results)
      keys = results.transform_keys { |name| @formula_keys.fetch(name, name) }
      FlatHash.expand(keys).freeze
    end

    def flatten_formulas(values)
      FlatHash.from_hash(values).transform_keys { |key| normalized_name(key) }
    end

    def flatten_inputs(values)
      FlatHash.from_hash(values).transform_keys { |key| normalized_name(key) }
    end

    def all_formula_names
      @formulas.keys
    end

    def normalized_name(name)
      @calculator.standardize_case(name.to_s)
    end

    def function_version_changed?
      version = current_function_version
      return false if version == @function_version

      @function_version = version
      true
    end

    def current_function_version
      registry = @calculator.function_registry
      registry.generation + Dentaku::AST::FunctionRegistry.default.generation
    end
  end
end
