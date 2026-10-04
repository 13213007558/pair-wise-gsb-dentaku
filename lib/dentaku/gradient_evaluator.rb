require 'dentaku/ast/arithmetic'
require 'dentaku/ast/case'
require 'dentaku/ast/combinators'
require 'dentaku/ast/comparators'
require 'dentaku/ast/functions/if'
require 'dentaku/ast/negation'
require 'dentaku/exceptions'
require 'dentaku/gradient_result'
require 'dentaku/gradient_rules'
require 'dentaku/numeric_parser'

module Dentaku
  class GradientEvaluator
    Trace = Struct.new(:id, :node, :value, :inputs, :operation, keyword_init: true)

    STATUS_PRIORITY = {
      function_error: 3,
      non_differentiable: 2,
      unknown_derivative: 1
    }.freeze

    def initialize(node, context)
      @node = node
      @context = context
      @cache = {}
      @formula_reference_cache = {}
      @tape = []
      @next_id = 0
      @variables = Hash.new { |hash, key| hash[key] = [] }
      @status = :ok
      @status_error = nil
    end

    def evaluate
      root = trace(@node)
      unless root.value.is_a?(Numeric)
        error = GradientError.new(:non_differentiable, "non-numeric result #{root.value.class}")
        return GradientResult.new(
          value: root.value,
          gradient: {},
          status: :non_differentiable,
          error: error
        )
      end

      adjoints = Hash.new(0)
      adjoints[root.id] = 1

      begin
        @tape.reverse_each do |trace|
          seed = adjoints[trace.id]
          next if seed.zero?

          local_derivatives(trace).each do |input, local|
            adjoints[input.id] += seed * local if local && input
          end
        end
      rescue GradientError => error
        record_status(error.status, error.reason)
        return failure_result(root, error.status, error)
      end

      gradient = supplied_numeric_variables.each_with_object({}) do |identifier, result|
        traces = @variables.fetch(identifier, [])
        result[identifier] = traces.sum { |trace| adjoints[trace.id] }
      end

      GradientResult.new(
        value: root.value,
        gradient: gradient,
        status: @status,
        error: @status_error
      )
    end

    def failure_result(root, status, error)
      GradientResult.new(
        value: root.value,
        gradient: {},
        status: status,
        error: error
      )
    end

    def supplied_numeric_variables
      @context.each_with_object([]) do |(key, value), keys|
        keys << key if !key.to_s.start_with?('__') && value.is_a?(Numeric)
      end
    end

    private

    def trace(node)
      if node.is_a?(AST::Identifier)
        value = @context.key?(node.identifier) ? @context[node.identifier] : node.value(@context)
        return trace_formula_reference(node, value) if value.is_a?(AST::Node) && @context.key?(node.identifier)
      end

      return @cache[node.object_id] if @cache.key?(node.object_id)

      value, inputs, operation = trace_node(node)
      trace = Trace.new(
        id: @next_id,
        node: node,
        value: value,
        inputs: inputs || [],
        operation: operation
      )
      @next_id += 1
      @tape << trace
      @variables[node.identifier] << trace if node.is_a?(AST::Identifier)
      @cache[node.object_id] = trace
    end

    def trace_node(node)
      case node
      when AST::Numeric, AST::Logical, AST::String, AST::DateTime, AST::Nil
        [node.value(@context), [], :constant]
      when AST::Identifier
        [node.value(@context), [], :variable]
      when AST::Grouping
        child = trace(node.instance_variable_get(:@node))
        [child.value, [child], :identity]
      when AST::Negation
        child = trace(node.instance_variable_get(:@node))
        [-numeric!(child.value), [child], :negate]
      when AST::Arithmetic
        trace_arithmetic(node)
      when AST::Comparator
        left = trace(node.left)
        right = trace(node.right)
        [left.value.public_send(node.operator, right.value), [left, right], :zero]
      when AST::And
        trace_and(node)
      when AST::Or
        trace_or(node)
      when AST::If
        trace_if(node)
      when AST::Case
        trace_case(node)
      when AST::Bitwise
        left = trace(node.left)
        right = trace(node.right)
        value = left.value.public_send(node.operator, right.value)
        operation = trace_non_differentiable(node.class.name.to_s, [left, right])
        [value, [left, right], operation]
      when AST::Function
        trace_function(node)
      else
        raise GradientError.new(:unknown_derivative, node.class.name.to_s)
      end
    end

    def trace_arithmetic(node)
      if node.is_a?(AST::Percentage)
        child = trace(node.left)
        return [numeric!(child.value) * 0.01, [child], :percentage]
      end

      left = trace(node.left)
      right = trace(node.right)
      value =
        case node
        when AST::Division
          divide(left.value, right.value)
        when AST::Modulo
          modulo(left.value, right.value)
        else
          begin
            numeric!(left.value).public_send(node.operator, numeric!(right.value))
          rescue StandardError => error
            raise error if error.is_a?(Dentaku::Error)

            raise GradientError.new(:function_error, error.message)
          end
        end

      [value, [left, right], node.class]
    end

    def trace_and(node)
      left = trace(node.left)
      return [left.value, [left], :zero] if !left.value

      right = trace(node.right)
      [right.value, [left, right], :zero]
    end

    def trace_or(node)
      left = trace(node.left)
      return [left.value, [left], :zero] if left.value

      right = trace(node.right)
      [right.value, [left, right], :zero]
    end

    def trace_if(node)
      predicate = trace(node.predicate)
      chosen = predicate.value ? trace(node.left) : trace(node.right)
      [chosen.value, [predicate, chosen], :branch]
    end

    def trace_case(node)
      switch = trace(node.switch.node)
      condition = nil
      traced_whens = []
      node.conditions.each do |candidate|
        when_node = trace(candidate.when.node)
        traced_whens << when_node
        if when_node.value == switch.value
          condition = candidate
          break
        end
      end

      if condition
        chosen = trace(condition.then.node)
        [chosen.value, [switch, *traced_whens, chosen], :case_branch]
      elsif node.else
        chosen = trace(node.else.node)
        [chosen.value, [switch, *traced_whens, chosen], :case_branch]
      else
        raise Dentaku::ArgumentError.for(:invalid_value)
      end
    end

    def trace_function(node)
      arguments = node.args.map { |argument| trace(argument) }
      values = arguments.map(&:value)

      begin
        value = invoke_function(node, values)
        [value, arguments, [:function, node.class]]
      rescue GradientError
        [value, arguments, [:function, node.class]]
      rescue MathDomainError => error
        gradient_error = GradientError.new(:function_error, error.message)
        record_status(gradient_error.status, gradient_error.reason)
        raise gradient_error
      rescue StandardError => error
        raise error if error.is_a?(Dentaku::Error)

        gradient_error = GradientError.new(:function_error, "#{function_name(node)}: #{error.message}")
        record_status(gradient_error.status, gradient_error.reason)
        raise gradient_error
      end
    end

    def trace_formula_reference(identifier, formula)
      return @formula_reference_cache[identifier.identifier] if @formula_reference_cache.key?(identifier.identifier)

      child = trace(formula)
      trace = Trace.new(
        id: @next_id,
        node: identifier,
        value: child.value,
        inputs: [child],
        operation: :identity
      )
      @next_id += 1
      @tape << trace
      @variables[identifier.identifier] << trace
      @formula_reference_cache[identifier.identifier] = trace
      @cache[identifier.object_id] = trace
    end

    def invoke_function(node, values)
      function_class = node.class
      if function_class.respond_to?(:invoke_with_evaluated_arguments)
        function_class.invoke_with_evaluated_arguments(node.args, @context)
      elsif function_class.respond_to?(:invoke)
        function_class.invoke(*values)
      else
        node.value(@context)
      end
    end

    def function_derivatives(trace)
      _function, function_class = trace.operation
      values = trace.inputs.map(&:value)
      argument_count = trace.inputs.length
      partials = GradientRules.derivative(function_class, values, numeric_or_nil(trace.value))
      partials = partials.is_a?(Array) ? partials : [partials]
      unless partials.length == argument_count
        raise GradientError.new(:function_error,
                                "#{function_class.name}: derivative returned #{partials.length} values for #{argument_count} arguments")
      end
      partials
    rescue GradientError => error
      record_status(error.status, error.reason)
      [0] * argument_count
    end

    def local_derivatives(trace)
      case trace.operation
      when :constant, :variable
        []
      when :identity, :negate, :percentage
        factor = { identity: 1, negate: -1, percentage: 0.01 }.fetch(trace.operation)
        trace.inputs.map { |input| [input, factor] }
      when :zero
        trace.inputs.map { |input| [input, 0] }
      when :branch
        trace.inputs.each_with_index.map do |input, index|
          [input, index.zero? ? 0 : 1]
        end
      when :case_branch
        trace.inputs.each_with_index.map { |input, _index| [input, input.equal?(trace.inputs.last) ? 1 : 0] }
      when ->(operation) { operation == AST::Addition || operation == AST::Subtraction }
        [[trace.inputs[0], 1], [trace.inputs[1], trace.operation == AST::Addition ? 1 : -1]]
      when ->(operation) { operation == AST::Multiplication }
        [[trace.inputs[0], trace.inputs[1].value], [trace.inputs[1], trace.inputs[0].value]]
      when ->(operation) { operation == AST::Division }
        left, right = trace.inputs.map(&:value)
        [[trace.inputs[0], 1.0 / right], [trace.inputs[1], -left.to_f / (right.to_f**2)]]
      when ->(operation) { operation == AST::Modulo }
        modulo_derivatives(trace)
      when ->(operation) { operation == AST::Exponentiation }
        exponent_derivatives(trace)
      when Array
        function_derivatives(trace).map.with_index { |partial, index| [trace.inputs[index], partial] }
      else
        raise GradientError.new(:unknown_derivative, trace.node.class.name.to_s)
      end
    end

    def exponent_derivatives(trace)
      base, exponent = trace.inputs.map(&:value)
      result = trace.value
      base_derivative = exponent.zero? || base.zero? ? 0 : result.to_f * exponent.to_f / base.to_f
      exponent_derivative = base.zero? || exponent.zero? ? 0 : result.to_f * Math.log(base.abs.to_f)
      [
        [trace.inputs[0], base_derivative],
        [trace.inputs[1], exponent_derivative]
      ].tap do |partials|
        finite = partials.all? { |_input, partial| partial.respond_to?(:finite?) && partial.finite? }
        if !finite || base.zero?
          raise GradientError.new(:non_differentiable, 'exponentiation')
        end
      end
    end

    def modulo_derivatives(trace)
      left, right = trace.inputs.map(&:value)
      raise GradientError.new(:non_differentiable, 'MOD at remainder zero') if trace.value.zero?

      quotient = ((left.to_f - trace.value.to_f) / right.to_f).round
      [[trace.inputs[0], 1], [trace.inputs[1], -quotient]]
    end

    def trace_non_differentiable(reason, _inputs)
      record_status(:non_differentiable, reason)
      :zero
    end

    def numeric!(value)
      Dentaku::NumericParser.ensure_numeric!(value)
    end

    def numeric_or_nil(value)
      value.is_a?(Numeric) ? value : nil
    end

    def divide(left, right)
      denominator = BigDecimal(numeric!(right).to_s, Float::DIG + 1)
      raise Dentaku::ZeroDivisionError if denominator.zero?

      numeric!(left) / denominator
    end

    def modulo(left, right)
      denominator = BigDecimal(numeric!(right).to_s, Float::DIG + 1)
      raise Dentaku::ZeroDivisionError if denominator.zero?

      numeric!(left) % denominator
    end

    def function_name(node)
      node.class.respond_to?(:name) ? node.class.name : node.class.to_s
    end

    def record_status(status, reason)
      return unless STATUS_PRIORITY.fetch(status, 0) > STATUS_PRIORITY.fetch(@status, 0)

      @status = status
      @status_error = GradientError.new(status, reason)
    end
  end
end
