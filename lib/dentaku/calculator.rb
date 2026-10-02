require 'dentaku/bulk_expression_solver'
require 'dentaku/dependency_resolver'
require 'dentaku/exceptions'
require 'dentaku/flat_hash'
require 'dentaku/parser'
require 'dentaku/string_casing'
require 'dentaku/token'

module Dentaku
  class Calculator
    include StringCasing
    attr_reader :result, :memory, :tokenizer, :case_sensitive,
                :nested_data_support, :ast_cache, :raw_date_literals,
                :decimal_context, :current_decimal_context

    def initialize(case_sensitive: false, aliases: nil, nested_data_support: true,
                   raw_date_literals: true, ast_cache: {},
                   cache_ast: nil, cache_dependency_order: nil, decimal_context: nil)
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
      @decimal_context = build_decimal_context(decimal_context)
      @current_decimal_context = nil
    end

    # explicitly configured aliases win; otherwise the module-level default is
    # resolved lazily so it can be set after this calculator was created
    def aliases
      @aliases || Dentaku.aliases
    end

    def self.add_function(name, type, body, callback = nil, volatile: false, decimal: nil,
                          decimal_implementation: nil)
      Dentaku::AST::FunctionRegistry.default.register(
        name, type, body, callback,
        volatile: volatile,
        decimal: decimal,
        decimal_implementation: decimal_implementation
      )
    end

    def self.add_functions(functions)
      functions.each { |(name, type, body, callback, volatile)| add_function(name, type, body, callback, volatile: !!volatile) }
    end

    def add_function(name, type, body, callback = nil, volatile: false, decimal: nil,
                     decimal_implementation: nil)
      @function_registry.register(name, type, body, callback, volatile: volatile, decimal: decimal,
                                  decimal_implementation: decimal_implementation)
      self
    end

    def add_functions(functions)
      functions.each { |(name, type, body, callback, volatile)| add_function(name, type, body, callback, volatile: !!volatile) }
      self
    end

    def disable_cache
      @disable_ast_cache = true
      yield(self) if block_given?
    ensure
      @disable_ast_cache = false
    end

    def evaluate(expression, data = {}, options = nil, &block)
      explicit_context, shared = evaluation_options(options)
      activate_decimal_context(explicit_context, shared)
      context = evaluation_context(data, :permissive)

      return evaluate_array(expression, context, false, &block) if expression.is_a?(Array)

      evaluate_node(expression, context)
    rescue Dentaku::Error => ex
      block.call(expression, ex) if block_given?
    end

    private def evaluate_array(expression, data, strict, &block)
      if strict
        expression.map { |expression_item| evaluate!(expression_item, data, { share_decimal_context: true }, &block) }
      else
        expression.map { |expression_item| evaluate(expression_item, data, { share_decimal_context: true }, &block) }
      end
    end

    def evaluate!(expression, data = {}, options = nil, &block)
      explicit_context, shared = evaluation_options(options)
      activate_decimal_context(explicit_context, shared)
      context = evaluation_context(data, :strict)

      return evaluate_array(expression, context, true, &block) if expression.is_a? Array

      evaluate_node(expression, context)
    end

    def decimal_signals
      current_decimal_context&.signals || []
    end

    private def evaluate_node(expression, context)
      store(context) do
        node = expression.is_a?(Dentaku::AST::Node) ? expression : ast(expression)
        unbound = node.dependencies(memory)

        unless unbound.empty?
          raise UnboundVariableError.new(unbound),
                "no value provided for variables: #{unbound.uniq.join(', ')}"
        end

        Dentaku.with_decimal_context(current_decimal_context) do
          node.value(memory)
        end
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
      return data if data.key?(:__evaluation_mode)

      data.merge(__evaluation_mode: evaluation_mode)
    end

    private def build_decimal_context(value)
      case value
      when nil then nil
      when Dentaku::DecimalContext then value
      when ::Hash then Dentaku::DecimalContext.new(**value.transform_keys(&:to_sym))
      else
        raise ::ArgumentError, "invalid decimal context #{value.inspect}"
      end
    end

    private def evaluation_options(options)
      return [@decimal_context, false] unless options

      [options.fetch(:decimal_context, @decimal_context), options.fetch(:share_decimal_context, false)]
    end

    private def activate_decimal_context(value, shared)
      context = value.is_a?(Dentaku::DecimalContext) ? value : build_decimal_context(value)
      context&.begin_calculation unless shared
      @current_decimal_context = context
      Thread.current[:dentaku_decimal_context] = context
    end

    private def activate_configured_decimal_context
      context = @decimal_context
      context&.begin_calculation
      @current_decimal_context = context
      Thread.current[:dentaku_decimal_context] = context
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
