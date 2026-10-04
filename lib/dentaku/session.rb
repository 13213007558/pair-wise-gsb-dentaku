require 'set'
require 'tsort'

require_relative 'evaluation_tracker'
require_relative 'exceptions'
require_relative 'flat_hash'

module Dentaku
  class TSort::Cyclic
    attr_accessor :evaluation_frame
  end

  class Session
    attr_reader :changed, :results, :formulas, :inputs

    def initialize(calculator = Calculator.new, formulas: {}, inputs: {}, strict: false)
      @calculator = calculator
      @strict = strict
      @inputs = {}
      @formulas = {}
      @output_keys = {}
      @states = {}
      @dependents = Hash.new { |hash, key| hash[key] = Set.new }
      @changed = {}
      @results = {}
      @formula_dirty = Set.new

      self.formulas = formulas
      store(inputs)
    end

    def self.create(formulas = {}, inputs = {}, calculator: Calculator.new, strict: false)
      new(calculator, formulas: formulas, inputs: inputs, strict: strict)
    end

    def formulas=(formulas)
      next_formulas, next_keys = flatten_formulas(formulas)
      removed = @formulas.keys - next_formulas.keys
      changed = next_formulas.select { |name, expression| @formulas[name] != expression }.keys
      removed.each { |name| @output_keys.delete(name) }
      @output_keys.merge!(next_keys)

      @formulas = next_formulas
      removed.each { |name| remove_state(name) }
      invalidate_names(removed)
      invalidate_names(changed)
      self
    end

    def update_formulas(formulas)
      flattened, keys = flatten_formulas(formulas)
      changed = flattened.select { |name, expression| @formulas[name] != expression }.keys
      @output_keys.merge!(keys)
      @formulas.merge!(flattened)
      invalidate_names(changed)
      self
    end

    def store(values)
      flattened = flatten_values(values)
      changed = flattened.select { |name, value| @inputs[name] != value }.keys

      @inputs = @inputs.merge(flattened)
      invalidate_names(seed_names(changed))
      self
    end
    alias_method :update_inputs, :store

    def update(values)
      store(values)
      calculate
    end

    def update!(values)
      store(values)
      calculate!
    end

    def delete(*names)
      names.flatten.each { |name| delete_name(normalize(name)) }
      self
    end

    def calculate
      calculate_session
    rescue Dentaku::Error, TSort::Cyclic
      raise if strict?

      expanded_results
    end

    def calculate!
      old_strict = @strict
      @strict = true
      calculate_session
    ensure
      @strict = old_strict
    end

    def dependencies(name = nil)
      name ? state_for(name)[:dependencies].dup : @states.transform_values { |state| state[:dependencies].dup }
    end

    def result(name)
      @states[normalize(name)]&.fetch(:value)
    end

    def error?(name = nil)
      if name
        @states[normalize(name)]&.fetch(:error)
      else
        @states.any? { |_name, state| state[:error] }
      end
    end

    private

    attr_reader :calculator, :states

    def strict?
      @strict
    end

    def calculate_session
      changed_names = Set.new
      dirty = dirty_formulas
      tracker = EvaluationTracker.new
      round_results = {}
      @round_results = round_results
      root_names = dirty.select { |name| formulas.key?(name) }
      active = Set.new
      @active_formulas = active
      @dirty_formulas = dirty
      @evaluation_context = build_context(tracker)
      previous_signatures = {}

      evaluate_formula = lambda do |name, force: false, top_level: false, formula_frame: nil|
        frame = formula_frame

        if top_level && round_results.key?(name)
          cached = round_results.fetch(name)
          cached[:error] ? raise(cached[:error]) : (return cached[:value])
        end

        if round_results.key?(name)
          cached = round_results[name]
          cached[:error] ? raise(cached[:error]) : (return cached[:value])
        end

        if active.include?(name)
          error = TSort::Cyclic.new("cyclic dependency: #{name}")
          error.evaluation_frame = frame
          raise error
        end

        state = @states[name]
        unless force
          stale = dirty.include?(name) || state_stale?(name, dirty)
          return state[:value] if state && !stale && !state[:error]
          raise state[:error] if state && !stale && state[:error]
        end

        expression = formulas.fetch(name) do
          raise UnboundVariableError.new([name]), "no value provided for variables: #{name}"
        end

        active.add(name)
        previous_signatures[name] = state_signature(state)
        frame = tracker.new_formula_frame if frame.nil?

        value = tracker.with_formula(frame) do
          ast = build_ast(name, expression)
          evaluate_ast(ast)
        end

        active.delete(name)
        store_state(
          name,
          value: value,
          error: nil,
          dependencies: frame.dependencies.to_a,
          function_versions: frame.functions.dup,
          volatile: frame.volatile
        )
        propagate_volatile(name)
        round_results[name] = { value: value, error: nil }
        changed_names.add(name) if previous_signatures[name] != state_signature(@states[name])
        value
      rescue TSort::Cyclic, Dentaku::Error => ex
        active.delete(name)
        previous_signatures[name] ||= state_signature(state)
        frame = ex.evaluation_frame if frame.nil? && ex.respond_to?(:evaluation_frame) && ex.evaluation_frame
        store_state(
          name,
          value: :undefined,
          error: ex,
          dependencies: frame.dependencies.to_a | unbound_names(ex),
          function_versions: frame.functions.dup,
          volatile: frame.volatile
        )
        propagate_volatile(name)
        round_results[name] = { value: :undefined, error: ex }
        changed_names.add(name) if previous_signatures[name] != state_signature(@states[name])
        raise
      ensure
        active.delete(name)
      end

      @evaluate_formula = evaluate_formula
      root_names.each do |name|
        begin
          evaluate_formula.call(name, force: true, top_level: true)
        rescue TSort::Cyclic, Dentaku::Error
          raise if strict?
        end
      end

      @changed = changed_names.each_with_object({}) do |name, hash|
        hash[output_key(name)] = @states[name][:value] if formulas.key?(name)
      end
      @results = expanded_results
      FlatHash.expand(@changed)
    ensure
      @evaluation_context = nil
      @evaluate_formula = nil
      @round_results = nil
      @active_formulas = nil
      @dirty_formulas = nil
      @formula_dirty.clear
    end

    def evaluate_ast(ast)
      return ast.value(@evaluation_context) unless ast.is_a?(::Array)

      ast.map do |node|
        node.value(@evaluation_context)
      rescue Dentaku::Error
        raise if strict?

        :undefined
      end
    end

    def build_ast(name, expression)
      if state_uses_changed_function?(name)
        calculator.clear_cache
      end

      calculator.ast(expression)
    end

    def build_context(tracker)
      formula_context = formulas.each_key.with_object({}) do |name, context|
        context[name] = lambda do
          if @active_formulas&.include?(name)
            error = TSort::Cyclic.new("cyclic dependency: #{name}")
            error.evaluation_frame = tracker.frame
            raise error
          end

          if @round_results.key?(name)
            cached = @round_results.fetch(name)
            raise cached[:error] if cached[:error]
            next cached[:value]
          end

          unless @dirty_formulas.include?(name)
            state = @states[name]
            raise state[:error] if state[:error]
            next state[:value]
          end

          formula_frame = tracker.new_formula_frame
          @evaluate_formula.call(name, formula_frame: formula_frame)
        end
      end

      inputs.merge(formula_context).merge(
        EvaluationTracker::CONTEXT_KEY => tracker,
        "__evaluation_mode" => strict? ? :strict : :permissive
      )
    end

    def dirty_formulas
      seeds = formulas.keys.select do |name|
        state = @states[name]
        state.nil? || @formula_dirty.include?(name) || state_uses_changed_function?(name) || state[:volatile]
      end

      reachable(seeds + @formula_dirty.to_a).to_set
    end

    def state_stale?(name, dirty)
      state = @states[name]
      return true unless state
      return true if dirty.include?(name)
      return true if state_uses_changed_function?(name)

      state[:dependencies].any? { |dependency| dirty.include?(dependency) }
    end

    def state_uses_changed_function?(name)
      state = @states[name]
      return false unless state

      state[:function_versions].any? do |function_name, (registry_id, version)|
        function_class = calculator.function_registry.get(function_name)
        function_class.nil? ||
          function_class.registry.nil? ||
          function_class.registry.object_id != registry_id ||
          function_class.function_version != version
      end
    end

    def store_state(name, value:, error:, dependencies:, function_versions:, volatile:)
      old_state = @states[name]
      old_dependencies = old_state&.dig(:dependencies) || []

      old_dependencies.each { |dependency| @dependents[dependency].delete(name) }
      @states[name] = {
        value: value,
        error: error,
        dependencies: dependencies,
        function_versions: function_versions,
        volatile: volatile
      }
      dependencies.each { |dependency| @dependents[dependency].add(name) }
    end

    def propagate_volatile(name)
      return unless @states[name][:volatile]

      @dependents[name].each do |dependent|
        state = @states[dependent]
        state[:volatile] = true if state
      end
    end

    def invalidate_names(names)
      names = names.map { |name| normalize(name) }.uniq
      reachable(names).each do |name|
        @formula_dirty.add(name)
      end
    end

    def reachable(names)
      seen = Set.new
      queue = names.uniq

      until queue.empty?
        name = queue.shift
        next if seen.include?(name)

        seen.add(name)
        queue.concat(@dependents[name].to_a)
      end

      seen.select { |name| formulas.key?(name) }
    end

    def delete_name(name)
      removed_formulas = formulas.keys.select { |key| key == name || key.start_with?("#{name}.") }
      removed_inputs = inputs.keys.select { |key| key == name || key.start_with?("#{name}.") }

      removed_formulas.each do |key|
        @formulas.delete(key)
        remove_state(key)
      end
      removed_inputs.each { |key| @inputs.delete(key) }

      invalidate_names(removed_formulas + removed_inputs + [name])
    end

    def remove_state(name)
      state = @states.delete(name)
      return unless state

      state[:dependencies].each { |dependency| @dependents[dependency].delete(name) }
    end

    def expanded_results
      values = formulas.keys.each_with_object({}) do |name, hash|
        hash[output_key(name)] = @states.fetch(name).fetch(:value)
      end
      @results = FlatHash.expand(values)
    end

    def output_key(name)
      @output_keys.fetch(name, name)
    end

    def flatten_formulas(formulas)
      flattened = FlatHash.from_hash(formulas)
      expressions = {}
      keys = {}

      flattened.each do |key, expression|
        name = normalize(key)
        expressions[name] = expression
        keys[name] = key
      end

      [expressions, keys]
    end

    def flatten_values(values)
      FlatHash.from_hash_with_intermediates(values).transform_keys { |key| normalize(key) }
    end

    def seed_names(names)
      names.flat_map { |name| name_prefixes(name) }.uniq
    end

    def name_prefixes(name)
      segments = name.to_s.split('.')
      segments.each_with_index.map { |_segment, index| segments[0..index].join('.') }
    end

    def state_for(name)
      @states.fetch(normalize(name))
    end

    def unbound_names(exception)
      exception.respond_to?(:unbound_variables) ? exception.unbound_variables : []
    end

    def state_signature(state)
      return nil unless state

      error = state[:error]
      [
        state[:value],
        error&.class,
        error&.message
      ]
    end

    def normalize(name)
      calculator.standardize_case(name.to_s)
    end
  end
end
