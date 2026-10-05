require 'dentaku/bulk_expression_solver'
require 'dentaku/dependency_resolver'
require 'dentaku/exceptions'
require 'dentaku/expression_function_definition'
require 'dentaku/expression_function_runtime'
require 'dentaku/flat_hash'
require 'dentaku/parser'
require 'dentaku/string_casing'
require 'dentaku/token'

module Dentaku
  class Calculator
    include StringCasing
    attr_reader :result, :memory, :tokenizer, :case_sensitive,
                :nested_data_support, :ast_cache, :raw_date_literals
    attr_accessor :max_function_call_depth, :max_function_operations

    def initialize(case_sensitive: false, aliases: nil, nested_data_support: true,
                   raw_date_literals: true, ast_cache: {},
                   cache_ast: nil, cache_dependency_order: nil,
                   max_function_call_depth: ExpressionFunctionRuntime::DEFAULT_MAX_DEPTH,
                   max_function_operations: ExpressionFunctionRuntime::DEFAULT_MAX_OPERATIONS)
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
      @max_function_call_depth = max_function_call_depth
      @max_function_operations = max_function_operations
      @expression_function_versions = {}
    end

    # explicitly configured aliases win; otherwise the module-level default is
    # resolved lazily so it can be set after this calculator was created
    def aliases
      @aliases || Dentaku.aliases
    end

    def self.add_function(name, type, body, callback = nil, volatile: false)
      Dentaku::AST::FunctionRegistry.default.register(name, type, body, callback, volatile: volatile)
    end

    def self.add_functions(functions)
      functions.each { |(name, type, body, callback, volatile)| add_function(name, type, body, callback, volatile: !!volatile) }
    end

    def add_function(name, type, body, callback = nil, volatile: false)
      @function_registry.register(name, type, body, callback, volatile: volatile)
      self
    end

    def add_functions(functions)
      functions.each { |(name, type, body, callback, volatile)| add_function(name, type, body, callback, volatile: !!volatile) }
      self
    end

    # Declares a function as a Dentaku expression so callers never have to
    # build Ruby code:
    #
    #   calculator.define_function('margin(revenue, cost)', '(revenue - cost) / revenue')
    #   calculator.define_function('margin(revenue, cost) = (revenue - cost) / revenue')
    #   calculator.define_function('taxed(price, rate = 0.1)', 'price * (1 + rate)')
    #   calculator.define_function('total(price)', 'price + fee', constants: { fee: 5 })
    #
    # Returns the ExpressionFunctionDefinition. Re-defining a name registers
    # a new version; formulas compiled earlier keep the version they were
    # compiled against (inspectable via the node's class definition), while
    # new compilations bind the current version.
    def define_function(signature, body = nil, constants: {})
      name = ExpressionFunctionDefinition.declaration_name(signature)
      version = (@expression_function_versions[name.downcase] || 0) + 1

      definition = ExpressionFunctionDefinition.build(
        signature,
        body,
        constants: constants,
        version: version,
        registry: @function_registry,
        parse_options: {
          aliases: aliases,
          case_sensitive: case_sensitive,
          raw_date_literals: raw_date_literals
        }
      )

      @function_registry.register_class(definition.name, definition.function_class)
      @expression_function_versions[definition.name.downcase] = definition.version
      definition
    end

    # the version an expression-defined function is currently registered
    # at, or nil when no expression function with that name exists
    def function_version(name)
      @expression_function_versions[name.to_s.downcase]
    end

    # the definition an expression-defined function currently resolves to,
    # or nil when the name is not an expression-defined function
    def function_definition(name)
      klass = @function_registry.get(name)
      klass.respond_to?(:definition) ? klass.definition : nil
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

    private def evaluate_array!(expression, data = {}, &block)
      expression.map { |e| evaluate!(e, data, &block) }
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

      data.merge(
        __evaluation_mode: evaluation_mode,
        ExpressionFunctionRuntime::CONTEXT_KEY => ExpressionFunctionRuntime.new(
          max_depth: max_function_call_depth,
          max_operations: max_function_operations
        )
      )
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
