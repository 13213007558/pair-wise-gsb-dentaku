require 'dentaku/bulk_expression_solver'
require 'dentaku/dependency_resolver'
require 'dentaku/exceptions'
require 'dentaku/flat_hash'
require 'dentaku/parser'
require 'dentaku/string_casing'
require 'dentaku/token'
require 'dentaku/gradient_evaluator'

module Dentaku
  class Calculator
    include StringCasing
    attr_reader :result, :memory, :tokenizer, :case_sensitive,
                :nested_data_support, :ast_cache, :raw_date_literals

    def initialize(case_sensitive: false, aliases: nil, nested_data_support: true,
                   raw_date_literals: true, ast_cache: {},
                   cache_ast: nil, cache_dependency_order: nil)
      clear
      @tokenizer = Tokenizer.new
      @case_sensitive = case_sensitive
      @aliases = aliases
      @nested_data_support = nested_data_support
      @raw_date_literals = raw_date_literals
      @ast_cache = ast_cache
      @cache_ast = cache_ast
      @cache_dependency_order = cache_dependency_order
      @disable_ast_cache = false
      @function_registry = Dentaku::AST::FunctionRegistry.new
    end

    # explicitly configured aliases win; otherwise the module-level default is
    # resolved lazily so it can be set after this calculator was created
    def aliases
      @aliases || Dentaku.aliases
    end

    def self.add_function(name, type, body, callback = nil, volatile: false, derivative: nil)
      Dentaku::AST::FunctionRegistry.default.register(
        name, type, body, callback, volatile: volatile, derivative: derivative
      )
    end

    def self.add_derivative(name, rule)
      Dentaku::AST::FunctionRegistry.default.register_derivative(name, rule)
    end

    def self.add_functions(functions)
      functions.each do |(name, type, body, callback, volatile, derivative)|
        add_function(
          name, type, body, callback,
          volatile: !!volatile, derivative: derivative
        )
      end
    end

    def add_function(name, type, body, callback = nil, volatile: false, derivative: nil)
      @function_registry.register(
        name, type, body, callback,
        volatile: volatile, derivative: derivative
      )
      self
    end

    def add_derivative(name, rule)
      @function_registry.register_derivative(name, rule)
      self
    end

    def add_functions(functions)
      functions.each do |(name, type, body, callback, volatile, derivative)|
        add_function(
          name, type, body, callback,
          volatile: !!volatile, derivative: derivative
        )
      end
      self
    end

    def disable_cache
      @disable_ast_cache = true
      yield(self) if block_given?
    ensure
      @disable_ast_cache = false
    end

    def evaluate(expression, data = {}, &block)
      context = evaluation_context(data, :permissive)
      return evaluate_array(expression, context, &block) if expression.is_a?(Array)

      evaluate!(expression, context)
    rescue Dentaku::Error => ex
      block.call(expression, ex) if block_given?
    end

    private def evaluate_array(expression, data = {}, &block)
      expression.map { |e| evaluate(e, data, &block) }
    end

    def evaluate!(expression, data = {}, &block)
      context = evaluation_context(data, :strict)
      return evaluate_array!(expression, context, &block) if expression.is_a? Array

      store(context) do
        node = ast(expression)
        unbound = node.dependencies(memory)

        unless unbound.empty?
          raise UnboundVariableError.new(unbound),
                "no value provided for variables: #{unbound.uniq.join(', ')}"
        end

        node.value(memory)
      end
    end

    def evaluate_with_gradient(expression, data = {}, *variable_positional, variables: nil, &block)
      evaluate_gradient_array(
        expression,
        data,
        gradient_variables(variables || variable_positional.first),
        false,
        &block
      )
    end

    def evaluate_with_gradient!(expression, data = {}, *variable_positional, variables: nil)
      evaluate_gradient_array(
        expression,
        data,
        gradient_variables(variables || variable_positional.first),
        true
      )
    end

    alias_method :evaluate_gradient, :evaluate_with_gradient
    alias_method :evaluate_gradient!, :evaluate_with_gradient!

    private def evaluate_array!(expression, data = {}, &block)
      expression.map { |e| evaluate!(e, data, &block) }
    end

    private def gradient_variables(variables)
      selected = Array(variables)
      raise ::ArgumentError, "variables must not be empty" if selected.empty?

      selected
    end

    private def evaluate_gradient_array(expression, data, variables, strict, &block)
      if expression.is_a?(Array)
        return expression.map do |item|
          evaluate_gradient_array(item, data, variables, strict)
        end
      end

      evaluate_gradient_once(expression, data, variables, strict)
    rescue Dentaku::Error => error
      raise if strict
      return block.call(expression, error) if block_given?

      nil
    end

    private def evaluate_gradient_once(expression, data, variables, strict)
      context = evaluation_context(data, strict ? :strict : :permissive)

      store(context) do
        node = ast(expression)
        value, gradient = GradientEvaluator.new(
          memory,
          variables.map { |name| standardize_case(name.to_s) },
          @function_registry
        ).evaluate(node)

        GradientResult.new(value, gradient)
      end
    end

    def solve!(expression_hash)
      BulkExpressionSolver.new(expression_hash, self).solve!
    end

    def solve(expression_hash, &block)
      BulkExpressionSolver.new(expression_hash, self).solve(&block)
    end

    def dependencies(expression, context = {})
      # dup inside the block: `store` now restores in place, so the caller
      # needs its own copy of the merged context rather than the live memory
      test_context = context.nil? ? {} : store(context) { memory.dup }

      case expression
      when Dentaku::AST::Node
        expression.dependencies(test_context)
      when Array
        expression.flat_map { |e| dependencies(e, context) }
      else
        ast(expression).dependencies(test_context)
      end
    end

    # every identifier the expression could reference, regardless of
    # branching: purely syntactic, ignores stored memory, and never
    # evaluates guards or functions
    def identifiers(expression)
      case expression
      when Dentaku::AST::Node
        expression.dependencies(AST::Node::STATIC_CONTEXT).uniq
      when Array
        expression.flat_map { |e| identifiers(e) }.uniq
      else
        ast(expression).dependencies(AST::Node::STATIC_CONTEXT).uniq
      end
    end

    def ast(expression)
      return expression if expression.is_a?(AST::Node)
      return expression.map { |e| ast(e) } if expression.is_a? Array

      @ast_cache.fetch(expression) {
        options = {
          aliases: aliases,
          case_sensitive: case_sensitive,
          function_registry: @function_registry,
          raw_date_literals: raw_date_literals
        }

        tokens = tokenizer.tokenize(expression, options)
        Parser.new(tokens, options).parse.tap do |node|
          @ast_cache[expression] = node if cache_ast?
        end
      }
    end

    def load_cache(ast_cache)
      @ast_cache = ast_cache
    end

    def clear_cache(pattern = :all)
      case pattern
      when :all
        @ast_cache = {}
      when String
        @ast_cache.delete(pattern)
      when Regexp
        @ast_cache.delete_if { |k, _| k =~ pattern }
      else
        raise ::ArgumentError
      end
    end

    def evaluation_context(data, evaluation_mode)
      data.key?(:__evaluation_mode) ? data : data.merge(__evaluation_mode: evaluation_mode)
    end

    def store(key_or_hash, value = nil)
      pairs = pairs_to_store(key_or_hash, value)

      unless block_given?
        pairs.each { |key, val| memory[key] = val }
        return self
      end

      # `evaluate!` routes every call through here, so snapshotting the whole
      # memory hash makes each evaluation scale with the number of stored
      # variables (#336). Undoing just the keys this call touched is O(pairs)
      # instead of O(memory) -- but it is only equivalent while nothing else
      # writes into memory during the block. The identifier cache does exactly
      # that, so when it is enabled we still need the wholesale snapshot to
      # keep cached values scoped to a single evaluation.
      if Dentaku.cache_identifier?
        restore = Hash[memory]
        pairs.each { |key, val| memory[key] = val }

        begin
          yield
        ensure
          @memory = restore
        end
      else
        undo = pairs.map { |key, _| [key, memory.key?(key), memory[key]] }
        pairs.each { |key, val| memory[key] = val }

        begin
          yield
        ensure
          undo.each { |key, present, val| present ? memory[key] = val : memory.delete(key) }
        end
      end
    end
    alias_method :bind, :store

    private def pairs_to_store(key_or_hash, value)
      if value.nil?
        key_or_hash = FlatHash.from_hash_with_intermediates(key_or_hash) if nested_data_support
        key_or_hash.map { |key, val| [standardize_case(key.to_s), val] }
      else
        [[standardize_case(key_or_hash.to_s), value]]
      end
    end

    def store_formula(key, formula)
      store(key, ast(formula))
    end

    def clear
      @memory = {}
    end

    def empty?
      memory.empty?
    end

    def cache_ast?
      return false if @disable_ast_cache

      @cache_ast.nil? ? Dentaku.cache_ast? : @cache_ast
    end

    def cache_dependency_order?
      @cache_dependency_order.nil? ? Dentaku.cache_dependency_order? : @cache_dependency_order
    end
  end
end
