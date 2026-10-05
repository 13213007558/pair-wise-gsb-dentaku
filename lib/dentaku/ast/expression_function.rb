require_relative '../exceptions'
require_relative 'function'
require_relative 'function_registry'

module Dentaku
  # Immutable record of one version of an expression-defined function.
  # Every (re)definition of a name produces a new FunctionDefinition with a
  # monotonically increasing version, so a compiled formula can always be
  # traced back to the exact definition it was compiled against via
  # `node.class.definition`.
  class FunctionDefinition
    attr_reader :name, :version, :params, :defaults, :body, :constants

    def initialize(name:, version:, params:, defaults:, body:, constants:)
      @name = name
      @version = version
      @params = params.freeze
      @defaults = defaults.freeze
      @body = body
      @constants = constants.freeze
    end

    def to_s
      "#{name}(#{params.join(', ')}) v#{version}"
    end

    def inspect
      "#<Dentaku::FunctionDefinition #{self}>"
    end

    DEFINITION_START = /\A\s*(?<name>[a-zA-Z_]\w*)\s*\(/.freeze
    PARAM_NAME = /\A[a-zA-Z_]\w*\z/.freeze

    # Parses the shorthand declaration form:
    #
    #   "margin(revenue, cost) = (revenue - cost) / revenue"
    #   # => ["margin", ["revenue", "cost"], {}, "(revenue - cost) / revenue"]
    #
    #   "pay(price, qty = 1, total = price * qty) = total"
    #   # => ["pay", ["price", "qty", "total"],
    #   #     {"qty" => "1", "total" => "price * qty"}, "total"]
    #
    # Returns [name, params, defaults, body].
    def self.parse(source)
      source = source.to_s
      match = DEFINITION_START.match(source)
      unless match
        raise Dentaku::ArgumentError.for(:invalid_value,
          expected: "function definition like 'name(param, ...) = expression'",
          actual: source)
      end

      open = match[0].rindex("(")
      close = matching_paren(source, open)
      rest = source[(close + 1)..].to_s.strip
      unless rest.start_with?("=")
        raise Dentaku::ArgumentError.for(:invalid_value,
          expected: "'=' between the parameter list and the body",
          actual: rest)
      end

      params = []
      defaults = {}
      split_top_level(source[(open + 1)...close]).each do |part|
        param_name, default = split_param(part)
        params << param_name
        defaults[param_name] = default if default
      end

      [match[:name], params, defaults, rest[1..].strip]
    end

    def self.matching_paren(source, open)
      depth = 0
      (open...source.length).each do |i|
        case source[i]
        when "(" then depth += 1
        when ")"
          depth -= 1
          return i if depth.zero?
        end
      end
      raise Dentaku::ArgumentError.for(:invalid_value, expected: "balanced parentheses", actual: source)
    end
    private_class_method :matching_paren

    def self.split_top_level(source)
      parts = []
      depth = 0
      current = +""
      source.each_char do |char|
        case char
        when "(", "[", "{"
          depth += 1
          current << char
        when ")", "]", "}"
          depth -= 1
          current << char
        when ","
          if depth.zero?
            parts << current
            current = +""
          else
            current << char
          end
        else
          current << char
        end
      end
      parts << current
      parts.map(&:strip).reject(&:empty?)
    end
    private_class_method :split_top_level

    def self.split_param(part)
      depth = 0
      part.each_char.with_index do |char, i|
        case char
        when "(", "[", "{" then depth += 1
        when ")", "]", "}" then depth -= 1
        when "="
          return [part[0...i].strip, part[(i + 1)..].strip] if depth.zero?
        end
      end
      [part.strip, nil]
    end
    private_class_method :split_param
  end

  # Tracks the nesting depth and total invocation count of expression-defined
  # functions during a single evaluation. One budget instance is created per
  # top-level evaluation and threaded through the (function-local) evaluation
  # contexts, so it bounds the whole call graph without ever touching the
  # calculator's memory.
  class CallBudget
    KEY = "__function_budget".freeze

    DEFAULT_MAX_DEPTH = 100
    DEFAULT_MAX_OPERATIONS = 10_000

    attr_reader :max_depth, :max_operations, :operations

    def initialize(max_depth: DEFAULT_MAX_DEPTH, max_operations: DEFAULT_MAX_OPERATIONS)
      @max_depth = max_depth
      @max_operations = max_operations
      @frames = []
      @operations = 0
    end

    def self.from_context(context)
      context[KEY] || context[KEY.to_sym]
    end

    def enter!(definition)
      @operations += 1
      frame = definition.to_s

      if @operations > max_operations
        raise FunctionCallBudgetError.new(:operations, limit: max_operations, call_chain: @frames + [frame])
      end

      if @frames.length >= max_depth
        raise FunctionCallBudgetError.new(:depth, limit: max_depth, call_chain: @frames + [frame])
      end

      @frames.push(frame)
    end

    def exit!
      @frames.pop
    end

    def call_chain
      @frames.dup
    end
  end

  module AST
    # A function whose implementation is itself a Dentaku expression, e.g.
    # `margin(revenue, cost) = (revenue - cost) / revenue`. Each definition
    # (version) of a name is a distinct subclass, so a parsed formula keeps
    # evaluating against the version that was current when it was compiled.
    #
    # Scoping rules (fixed):
    # * the body sees exactly its parameters and the constants captured at
    #   definition time -- never the caller's variables;
    # * parameters (including defaults) shadow same-named constants;
    # * a default value may reference the parameters declared before it;
    # * callee references are bound when the body is parsed; unknown callees
    #   become forward declarations that a later define_function fills in
    #   place, which is what allows mutual recursion;
    # * recursion (direct or mutual) is allowed and bounded by the call
    #   budget; a recursive call always targets the function's own version.
    class ExpressionFunction < Function
      RESERVED_CONTEXT_PREFIX = "__".freeze

      # Registry facade used while parsing a function body: names that are
      # not defined yet are forward-declared as placeholders in the real
      # registry, so (mutually) recursive definitions can be parsed before
      # all of their callees exist.
      class ForwardRegistry
        def initialize(target)
          @target = target
        end

        def get(name)
          @target.get(name) || ExpressionFunction.placeholder(@target, name)
        end
      end

      class << self
        attr_reader :definition, :body_node, :default_nodes
        attr_accessor :forward_name

        # false for forward declarations that no define_function has filled yet
        def installed?
          !@body_node.nil?
        end

        # registry entries are classes; true for (sub)classes of
        # ExpressionFunction, false for Ruby-lambda functions and builtins
        def expression_class?(entry)
          entry.is_a?(Class) && entry <= ExpressionFunction
        end

        def version
          @definition&.version
        end

        def min_param_count
          installed? ? @definition.params.length - @default_nodes.length : 0
        end

        def max_param_count
          installed? ? @definition.params.length : Float::INFINITY
        end

        def assign_display_name
          label = @definition ? @definition.name : @forward_name
          ruby_name = "Dentaku::AST::ExpressionFunction::#{label.to_s.capitalize.gsub(/\W/, '_')}"
          define_singleton_method(:name) { ruby_name }
          define_singleton_method(:to_s) do
            installed? ? "#{ruby_name} (#{@definition})" : "#{ruby_name} (forward declaration)"
          end
          define_singleton_method(:inspect) { to_s }
        end

        def install(definition, default_nodes, body_node)
          @definition = definition
          @default_nodes = default_nodes
          @body_node = body_node
          assign_display_name
        end

        # Registers a forward declaration so a body can be parsed before its
        # callees are defined; the placeholder is filled in place when the
        # definition for its name finally arrives.
        def placeholder(registry, name)
          key = name.to_s.downcase
          klass = Class.new(ExpressionFunction)
          klass.forward_name = key
          klass.assign_display_name
          registry.register_class(key, klass)
          klass
        end

        # Defines (or redefines) an expression function in +registry+.
        # +parse+ is a callable turning an expression source string into an
        # AST; body/defaults may also be given as AST::Node instances.
        # Returns the FunctionDefinition for the new version.
        def define(registry, name, params, parse:, body:, defaults: {}, constants: {})
          key = name.to_s.downcase
          params = params.map(&:to_s)
          defaults = defaults.transform_keys(&:to_s)
          constants = constants.transform_keys(&:to_s)

          validate_signature!(params, defaults, constants)

          existing = registry.own(key)
          klass, version =
            if expression_class?(existing)
              existing.installed? ? [Class.new(ExpressionFunction), existing.version + 1] : [existing, 1]
            else
              [Class.new(ExpressionFunction), 1]
            end

          # register before parsing the body so the function can reference
          # itself (and, via placeholders, mutually recursive partners)
          registry.register_class(key, klass)

          begin
            registered_before = registry.keys
            node_or_parse = ->(src) { src.is_a?(Node) ? src : parse.call(src) }
            body_node = node_or_parse.call(body)
            default_nodes = build_defaults(params, defaults, constants, node_or_parse)
            validate_body!(body_node, params, constants)
          rescue Exception
            # a failed definition must leave no trace in the registry: drop
            # any forward declarations the aborted parse introduced
            (registry.keys - registered_before).each do |leftover|
              entry = registry.own(leftover)
              registry.delete(leftover) if expression_class?(entry) && !entry.installed?
            end
            existing ? registry.register_class(key, existing) : registry.delete(key)
            raise
          end

          definition = Dentaku::FunctionDefinition.new(
            name: key, version: version, params: params,
            defaults: defaults, body: body, constants: constants
          )
          klass.install(definition, default_nodes, body_node)
          definition
        end

        private

        def validate_signature!(params, defaults, constants)
          (params + constants.keys).each do |identifier|
            unless identifier.match?(FunctionDefinition::PARAM_NAME)
              raise Dentaku::ArgumentError.for(:invalid_value, expected: "identifier", actual: identifier)
            end
            if identifier.start_with?(RESERVED_CONTEXT_PREFIX)
              raise Dentaku::ArgumentError.for(:invalid_value, actual: "reserved identifier '#{identifier}'")
            end
          end

          duplicate = params.tally.find { |_, count| count > 1 }
          if duplicate
            raise Dentaku::ArgumentError.for(:invalid_value, actual: "duplicate parameter '#{duplicate.first}'")
          end

          stray = defaults.keys - params
          unless stray.empty?
            raise Dentaku::ArgumentError.for(:invalid_value, actual: "defaults given for non-parameters: #{stray.join(', ')}")
          end
        end

        def build_defaults(params, defaults, constants, node_or_parse)
          default_nodes = {}
          params.each_with_index do |param, i|
            next unless defaults.key?(param)

            node = node_or_parse.call(defaults[param])
            visible = params.first(i) + constants.keys
            unknown = node.dependencies(Node::STATIC_CONTEXT).uniq - visible
            unless unknown.empty?
              raise Dentaku::ArgumentError.for(:invalid_value,
                actual: "default for '#{param}' references unknown names: #{unknown.join(', ')} " \
                        "(defaults may only use earlier parameters and definition-time constants)")
            end
            default_nodes[param] = node
          end
          default_nodes
        end

        def validate_body!(body_node, params, constants)
          unknown = body_node.dependencies(Node::STATIC_CONTEXT).uniq - params - constants.keys
          unless unknown.empty?
            raise Dentaku::ArgumentError.for(:invalid_value,
              actual: "function body references unknown names: #{unknown.join(', ')} " \
                      "(expression functions only see their parameters and definition-time constants)")
          end
        end
      end

      def value(context = {})
        klass = self.class
        unless klass.installed?
          raise Dentaku::UndefinedFunctionError.new(klass.forward_name)
        end

        budget = CallBudget.from_context(context) || CallBudget.new
        budget.enter!(klass.definition)

        begin
          klass.body_node.value(build_local_context(context, budget))
        rescue Dentaku::Error => e
          unless e.call_chain
            chain = budget.call_chain
            e.call_chain = chain
            raise e.exception("#{e.message} [function call chain: #{chain.join(' -> ')}]")
                    .tap { |copy| copy.set_backtrace(e.backtrace) }
          end
          raise
        ensure
          budget.exit!
        end
      end

      private

      # The body evaluates in a fresh scope built from the definition-time
      # constants and the bound arguments; the caller's context only
      # contributes argument values and reserved ("__") evaluation settings.
      # Nothing is ever written back, so a failed call cannot pollute the
      # calculator's memory.
      def build_local_context(caller_context, budget)
        klass = self.class
        definition = klass.definition

        values = @args.map { |arg| arg.value(caller_context) }
        min = klass.min_param_count
        max = klass.max_param_count
        unless values.length.between?(min, max)
          raise Dentaku::ArgumentError.for(:wrong_number_of_arguments,
            function_name: definition.name,
            actual: values.length,
            expected: min == max ? min : (min..max))
        end

        local = {}
        caller_context.each do |key, val|
          local[key.to_s] = val if key.to_s.start_with?(RESERVED_CONTEXT_PREFIX)
        end
        local[CallBudget::KEY] = budget

        definition.constants.each { |name, val| local[name] = val }

        definition.params.each_with_index do |param, i|
          local[param] = i < values.length ? values[i] : klass.default_nodes[param].value(local)
        end

        local
      end
    end
  end
end
