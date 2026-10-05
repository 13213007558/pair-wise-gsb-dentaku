require 'dentaku/ast/expression_function'
require 'dentaku/exceptions'
require 'dentaku/parser'
require 'dentaku/string_casing'
require 'dentaku/tokenizer'

module Dentaku
  # A function declared as a Dentaku expression instead of a Ruby lambda:
  #
  #   calculator.define_function('margin(revenue, cost)', '(revenue - cost) / revenue')
  #   calculator.define_function('margin(revenue, cost) = (revenue - cost) / revenue')
  #   calculator.define_function('taxed(price, rate = 0.1)', 'price * (1 + rate)')
  #   calculator.define_function('total(price)', 'price + fee', constants: { fee: 5 })
  #
  # Semantics, fixed once for all callers:
  #
  # * parameters are positional; trailing parameters may declare defaults,
  #   and a default may reference the constants and the parameters declared
  #   before it
  # * +constants+ are captured (by value) when the function is defined;
  #   inside the body they always win over same-named variables the caller
  #   happens to store, and parameters in turn shadow constants
  # * bodies are hermetic: every identifier must be a parameter or a
  #   constant, so a call never reads (or writes) the caller's memory
  # * calls to functions that already exist bind at definition time; calls
  #   to not-yet-defined functions (forward references, direct and mutual
  #   recursion) resolve at call time against the calculator's registry
  # * recursion is allowed, bounded by the calculator's call-depth and
  #   operation-count budgets
  class ExpressionFunctionDefinition
    include StringCasing

    # Function lookup used while parsing an expression function body:
    # names the calculator already knows (built-ins, Ruby functions,
    # previously defined expression functions) bind immediately; unknown
    # names become LateBoundFunction nodes so they can be defined later.
    class Scope
      def initialize(registry)
        @registry = registry
        @late_bound = {}
      end

      def get(name)
        @registry.get(name) || @late_bound[name.to_s.downcase] ||= AST::LateBoundFunction.build(name, @registry)
      end
    end

    Parameter = Struct.new(:name, :default_source, :default_node, keyword_init: true) do
      def default?
        !default_node.nil?
      end
    end

    NAME_PATTERN = /\A[a-zA-Z_]\w*\z/.freeze
    SIGNATURE_PATTERN = /\A\s*([a-zA-Z_]\w*)\s*\(/.freeze

    # context keys a body is allowed to observe from the caller's context:
    # the evaluation mode and the shared runtime -- never user variables
    INHERITED_CONTEXT_KEYS = [
      "__evaluation_mode".freeze,
      ExpressionFunctionRuntime::CONTEXT_KEY
    ].freeze

    attr_reader :name, :version, :parameters, :constants, :body_source, :body, :case_sensitive

    def self.build(signature, body, constants:, version:, registry:, parse_options:)
      name, parameter_specs, body = parse_declaration(signature, body)
      scope = Scope.new(registry)

      parameters = parameter_specs.map do |param_name, default_source|
        default_node = default_source && parse_expression(default_source, scope, parse_options)
        Parameter.new(name: param_name, default_source: default_source, default_node: default_node)
      end

      body_node = parse_expression(body, scope, parse_options)

      new(
        name: name,
        version: version,
        parameters: parameters,
        constants: constants,
        body_source: body,
        body: body_node,
        case_sensitive: parse_options.fetch(:case_sensitive, false)
      )
    end

    # accepts either ('name(params)', 'body') or the single-string
    # declaration 'name(params) = body'
    def self.parse_declaration(signature, body)
      source = signature.to_s
      name = declaration_name(signature)
      open_index = SIGNATURE_PATTERN.match(source).end(0) - 1
      close_index = find_matching_paren(source, open_index)
      raise FunctionDefinitionError, "unbalanced parenthesis in signature: #{source.inspect}" if close_index.nil?

      rest = source[(close_index + 1)..].strip
      if body.nil? && rest.start_with?("=")
        body = rest[1..].strip
        rest = ""
      end

      unless rest.empty?
        raise FunctionDefinitionError, "unexpected tokens after function signature: #{rest.inspect}"
      end

      if body.nil? || body.to_s.strip.empty?
        raise FunctionDefinitionError, "missing body for function #{name}"
      end

      [name, parse_parameters(source[(open_index + 1)...close_index]), body.to_s]
    end

    def self.declaration_name(signature)
      match = SIGNATURE_PATTERN.match(signature.to_s)
      raise FunctionDefinitionError, "invalid function signature: #{signature.to_s.inspect}" if match.nil?

      match[1]
    end

    def self.find_matching_paren(source, open_index)
      depth = 0
      quote = nil
      index = open_index

      while index < source.length
        char = source[index]
        if quote
          quote = nil if char == quote
        elsif char == "'" || char == '"'
          quote = char
        elsif char == "("
          depth += 1
        elsif char == ")"
          depth -= 1
          return index if depth.zero?
        end
        index += 1
      end

      nil
    end

    def self.parse_parameters(params_source)
      return [] if params_source.strip.empty?

      split_top_level(params_source, ",").map do |spec|
        name, default = split_top_level(spec, "=", 2)
        name = name.to_s.strip

        unless NAME_PATTERN.match?(name)
          raise FunctionDefinitionError, "invalid parameter name in #{spec.strip.inspect}"
        end

        default = default&.strip
        [name, default.nil? || default.empty? ? nil : default]
      end
    end

    # splits on a separator that appears outside parentheses, brackets and
    # string quotes, so defaults like "if(a, 1, 2)" stay in one piece
    def self.split_top_level(source, separator, limit = nil)
      parts = []
      current = +""
      depth = 0
      quote = nil

      source.each_char do |char|
        if quote
          quote = nil if char == quote
          current << char
        elsif char == "'" || char == '"'
          quote = char
          current << char
        elsif char == "(" || char == "[" || char == "{"
          depth += 1
          current << char
        elsif char == ")" || char == "]" || char == "}"
          depth -= 1
          current << char
        elsif char == separator && depth.zero? && (limit.nil? || parts.length < limit - 1)
          parts << current
          current = +""
        else
          current << char
        end
      end

      parts << current
      parts
    end

    def self.parse_expression(source, scope, parse_options)
      options = parse_options.merge(function_registry: scope)
      tokens = Tokenizer.new.tokenize(source, options)
      Parser.new(tokens, options).parse
    end

    def initialize(name:, version:, parameters:, constants:, body_source:, body:, case_sensitive:)
      @case_sensitive = case_sensitive
      @name = name
      @version = version
      @parameters = normalize_parameters(parameters)
      @constants = normalize_constants(constants)
      @body_source = body_source
      @body = body

      validate_structure!
      validate_scope!
    end

    def label
      "#{name}(v#{version})"
    end

    def required_param_count
      parameters.count { |param| !param.default? }
    end

    def pure?
      body.pure?
    end

    # the AST class formulas bind to when they call this function; each
    # definition gets its own class so a redefinition never retroactively
    # changes already-compiled formulas
    def function_class
      @function_class ||= Class.new(AST::ExpressionFunction).tap do |klass|
        klass.definition = self
      end
    end

    # hermetic evaluation context for the body: reserved runtime keys plus
    # the captured constants plus the bound parameters -- nothing from the
    # caller's memory can leak in, and nothing written here leaks out
    def child_context(caller_context, arg_nodes)
      child = {}
      INHERITED_CONTEXT_KEYS.each do |key|
        child[key] = caller_context[key] if caller_context.key?(key)
      end
      constants.each { |key, value| child[key] = value }

      parameters.each_with_index do |param, index|
        child[param.name] =
          if index < arg_nodes.length
            arg_nodes[index].value(caller_context)
          else
            param.default_node.value(child)
          end
      end

      child
    end

    def to_s
      "#<Dentaku::ExpressionFunctionDefinition #{label} #{signature_source} = #{body_source}>"
    end

    def inspect
      to_s
    end

    def signature_source
      params = parameters.map { |param| param.default? ? "#{param.name} = #{param.default_source}" : param.name }
      "#{name}(#{params.join(', ')})"
    end

    private

    def normalize_parameters(parameters)
      parameters.map do |param|
        Parameter.new(
          name: standardize_case(param.name),
          default_source: param.default_source,
          default_node: param.default_node
        )
      end.freeze
    end

    def normalize_constants(constants)
      constants.each_with_object({}) do |(key, value), normalized|
        name = key.to_s
        unless NAME_PATTERN.match?(name)
          raise FunctionDefinitionError, "invalid constant name #{name.inspect} for function #{self.name}"
        end
        normalized[standardize_case(name)] = value
      end.freeze
    end

    def validate_structure!
      duplicates = parameters.group_by(&:name).select { |_, group| group.length > 1 }.keys
      unless duplicates.empty?
        raise FunctionDefinitionError, "duplicate parameter(s) #{duplicates.join(', ')} in #{signature_source}"
      end

      seen_default = false
      parameters.each do |param|
        if param.default?
          seen_default = true
        elsif seen_default
          raise FunctionDefinitionError,
                "required parameter #{param.name} follows a default parameter in #{signature_source}"
        end
      end
    end

    # every identifier in the body and in the defaults must resolve to a
    # parameter or a captured constant; a default may only reference
    # constants and the parameters declared before it
    def validate_scope!
      bound = constants.keys

      parameters.each do |param|
        if param.default?
          unbound = param.default_node.dependencies(static_context(bound))
          unless unbound.empty?
            raise FunctionDefinitionError,
                  "default of #{param.name} in #{signature_source} references unknown: #{unbound.uniq.join(', ')}"
          end
        end
        bound = bound + [param.name]
      end

      unbound = body.dependencies(static_context(bound))
      return if unbound.empty?

      raise UnboundVariableError.new(unbound),
            "no value provided for variables: #{unbound.uniq.join(', ')} " +            "(bodies of expression-defined functions may only use their parameters and constants)"
    end

    def static_context(bound_names)
      AST::Node::STATIC_CONTEXT.merge(bound_names.map { |name| [name, nil] }.to_h)
    end
  end
end
