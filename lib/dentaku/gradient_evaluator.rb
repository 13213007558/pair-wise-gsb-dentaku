require 'bigdecimal'
require_relative 'ast'

module Dentaku
  class GradientEvaluator
    STATUS_PRIORITY = {
      ok: 0,
      non_differentiable: 1,
      unknown_derivative: 2,
      custom_function_error: 3,
      evaluation_error: 4
    }.freeze

    Dual = Struct.new(:value, :tangent, :kink, :partials, keyword_init: true) do
      def self.constant(value)
        new(value: value, tangent: {}, kink: false, partials: nil)
      end
    end

    Reason = Struct.new(:status, :message, keyword_init: true)

    def initialize(node, context = {}, function_registry: nil)
      @node = node
      @context = context
      @status = :ok
      @reasons = []
      @cache = {}
    end

    def call
      output = evaluate(@node)
      tangent_values = output.tangent.values
      if !tangent_values.empty? && tangent_values.any? { |value| value.respond_to?(:finite?) && !value.finite? }
        mark(:non_differentiable, 'derivative is not finite')
        output = Dual.new(value: output.value, tangent: {}, kink: true)
      end

      result = GradientResult.new(
        result: output.value,
        gradient: output.tangent.reject { |_, derivative| derivative == 0 },
        status: @status,
        reasons: @reasons
      )
      result
    rescue Dentaku::UnboundVariableError
      raise
    rescue Dentaku::Error => error
      failure_result(:evaluation_error, error.message)
    rescue GradientEvaluationError => error
      failure_result(error.status, error.message)
    end

    private

    class GradientEvaluationError < StandardError
      attr_reader :status

      def initialize(status, message)
        @status = status
        super(message)
      end
    end

    def failure_result(status, message)
      GradientResult.new(
        result: nil,
        gradient: {},
        status: status,
        reasons: [Reason.new(status: status, message: message)]
      )
    end

    def evaluate(node)
      return @cache[node.object_id] if @cache.key?(node.object_id)

      dual = case node
             when Dentaku::AST::RubyMath
               evaluate_ruby_math(node)
             when Dentaku::AST::If
               evaluate_if(node)
             when Dentaku::AST::Xor
               evaluate_xor(node)
             when Dentaku::AST::Function
               evaluate_function(node)
             when Dentaku::AST::Operation
               send("evaluate_#{class_name(node)}", node)
             else
               send("evaluate_#{class_name(node)}", node)
             end
      @cache[node.object_id] = dual
      dual
    end

    def class_name(node)
      node.class.name.to_s.split('::').last
             .gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
             .gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
             .downcase
    end

    def constant(value)
      Dual.constant(value)
    end

    def variable(value, name)
      value = numeric_value(value)
      Dual.new(value: value, tangent: { name => 1 }, kink: false)
    end

    def numeric_dual(dual)
      value = numeric_value(dual.value)
      dual.dup.tap { |copy| copy.value = value }
    end

    def numeric_value(value, *)
      NumericParser.ensure_numeric!(value)
    end

    def merge_tangents(*tangents)
      tangents.compact.each_with_object({}) do |tangent, merged|
        tangent.each { |name, value| merged[name] = merged.fetch(name, 0) + value }
      end
    end

    def scale(tangent, factor)
      return tangent if factor == 1
      return {} if factor == 0 || tangent.empty?

      tangent.transform_values { |value| value * factor }
    end

    def mark(status, message)
      @reasons << Reason.new(status: status, message: message)
      @status = status if STATUS_PRIORITY.fetch(status) > STATUS_PRIORITY.fetch(@status)
    end

    def boolean_dual(value, tangent, kink: false)
      mark(:non_differentiable, 'boolean result is not differentiable') if kink && !tangent.empty?
      Dual.new(value: value, tangent: tangent, kink: kink)
    end

    def evaluate_numeric(node); evaluate_literal(node); end
    def evaluate_numeric_literal(node); evaluate_literal(node); end
    def evaluate_logical(node); evaluate_literal(node); end
    def evaluate_string(node); evaluate_literal(node); end
    def evaluate_date_time(node); evaluate_literal(node); end
    def evaluate_nil(_node); constant(nil); end

    def evaluate_literal(node)
      constant(node.value)
    end

    def evaluate_identifier(node)
      stored = @context[node.identifier]
      return evaluate(stored) if stored.is_a?(Dentaku::AST::Node)

      value = node.value(@context)
      return value if value.is_a?(Dual)

      value.is_a?(Numeric) ? variable(value, node.identifier) : constant(value)
    end

    def evaluate_grouping(node)
      evaluate(node.instance_variable_get(:@node))
    end

    def evaluate_case_else(node); evaluate_wrapper(node, :@node); end
    def evaluate_case_then(node); evaluate_wrapper(node, :@node); end
    def evaluate_case_switch_variable(node); evaluate_wrapper(node, :@node); end
    def evaluate_case_when(node); evaluate_wrapper(node, :@node); end

    def evaluate_wrapper(node, variable_name)
      evaluate(node.instance_variable_get(variable_name))
    end

    def evaluate_case_conditional(node)
      when_dual = evaluate(node.instance_variable_get(:@when))
      then_dual = evaluate(node.instance_variable_get(:@then))
      Dual.new(
        value: [when_dual.value, then_dual.value],
        tangent: merge_tangents(when_dual.tangent, then_dual.tangent),
        kink: when_dual.kink || then_dual.kink
      )
    end

    def evaluate_case(node)
      switch_dual = evaluate(node.instance_variable_get(:@switch))
      conditions = node.instance_variable_get(:@conditions)
      else_node = node.instance_variable_get(:@else)

      conditions.each do |condition|
        when_dual = evaluate(condition.instance_variable_get(:@when))
        if when_dual.value == switch_dual.value
          chosen = evaluate(condition.instance_variable_get(:@then))
          chosen.dup.tap { |dual| dual.kink ||= switch_dual.kink || when_dual.kink }.then do |dual|
            mark(:non_differentiable, 'CASE is on a non-differentiable boundary') if dual.kink
            return dual
          end
        end
      end

      raise Dentaku::ArgumentError.for(:invalid_value) unless else_node

      chosen = evaluate(else_node)
      chosen.dup.tap { |dual| dual.kink ||= switch_dual.kink }
    end

    def evaluate_array(node)
      elements = node.instance_variable_get(:@elements).map { |element| evaluate(element) }
      Dual.new(
        value: elements.map(&:value),
        tangent: merge_tangents(*elements.map(&:tangent)),
        kink: elements.any?(&:kink),
        partials: elements
      )
    end

    def evaluate_access(node)
      structure_dual = evaluate(node.instance_variable_get(:@structure))
      index_dual = evaluate(node.instance_variable_get(:@index))
      value = structure_dual.value[index_dual.value]
      return constant(value) unless value.is_a?(Numeric)

      if structure_dual.value.is_a?(Array)
        selected = structure_dual.partials&.at(index_dual.value)
        return constant(value) unless selected
        return selected.dup unless index_dual.kink

        mark(:non_differentiable, 'array access is non-differentiable at a variable index boundary')
        Dual.new(value: selected.value, tangent: {}, kink: true)
      else
        mark(:unknown_derivative, 'hash access derivatives are not supported')
        Dual.new(value: value, tangent: {}, kink: false)
      end
    end

    def evaluate_addition(node); binary_additive(node, :+); end
    def evaluate_subtraction(node); binary_additive(node, :-); end
    def evaluate_multiplication(node); binary_multiplication(node); end
    def evaluate_division(node); binary_division(node); end
    def evaluate_modulo(node); binary_modulo(node); end
    def evaluate_exponentiation(node); evaluate_power(node); end

    def binary_additive(node, operator)
      left = evaluate(node.left)
      right = evaluate(node.right)
      l = numeric_dual(left)
      r = numeric_dual(right)
      value = begin
        l.value.public_send(operator, r.value)
      rescue ::TypeError => error
        raise Dentaku::ArgumentError.for(:incompatible_type, actual: r.value, expected: l.value.class), error.message
      rescue ::ArgumentError, ::RangeError, ::FloatDomainError => error
        raise Dentaku::ArgumentError.for(:invalid_value, actual: r.value), error.message
      end

      value = validate_arithmetic_result(value, l.value, r.value)
      right_tangent = operator == :- ? scale(r.tangent, -1) : r.tangent
      Dual.new(
        value: value,
        tangent: merge_tangents(l.tangent, right_tangent),
        kink: l.kink || r.kink
      )
    end

    def binary_multiplication(node)
      left = numeric_dual(evaluate(node.left))
      right = numeric_dual(evaluate(node.right))
      value = validate_arithmetic_result(left.value * right.value, left.value, right.value)
      left_factor = (left.value.zero? && right.value.zero?) ? 0 : right.value
      right_factor = (left.value.zero? && right.value.zero?) ? 0 : left.value
      tangent = merge_tangents(
        scale(left.tangent, left_factor),
        scale(right.tangent, right_factor)
      )
      Dual.new(value: value, tangent: tangent, kink: left.kink || right.kink)
    end

    def validate_arithmetic_result(result, left, right)
      return result unless result.is_a?(::Numeric) && result.respond_to?(:finite?) && !result.finite?
      return result if nonfinite?(left) || nonfinite?(right)

      raise Dentaku::ArgumentError.for(:invalid_value, actual: right), 'arithmetic result is not finite'
    end

    def nonfinite?(value)
      value.is_a?(::Numeric) && value.respond_to?(:finite?) && !value.finite?
    end

    def evaluate_negation(node)
      child = numeric_dual(evaluate(node.instance_variable_get(:@node)))
      child.dup.tap do |dual|
        dual.value = dual.value * -1
        dual.tangent = scale(dual.tangent, -1)
      end
    end

    def evaluate_percentage(node)
      child = numeric_dual(evaluate(node.left))
      Dual.new(
        value: child.value * 0.01,
        tangent: scale(child.tangent, 0.01),
        kink: child.kink
      )
    end

    def evaluate_division(node)
      left = numeric_dual(evaluate(node.left))
      right = numeric_dual(evaluate(node.right))
      denominator = BigDecimal(right.value.to_s, Float::DIG + 1)
      raise Dentaku::ZeroDivisionError if denominator.zero?

      value = NumericParser.ensure_numeric!(left.value / denominator)
      denominator_squared = denominator * denominator
      tangent = merge_tangents(
        scale(left.tangent, 1 / denominator),
        scale(right.tangent, -left.value / denominator_squared)
      )
      Dual.new(value: value, tangent: tangent, kink: left.kink || right.kink)
    end

    def evaluate_modulo(node)
      left = numeric_dual(evaluate(node.left))
      right = numeric_dual(evaluate(node.right))
      denominator = BigDecimal(right.value.to_s, Float::DIG + 1)
      raise Dentaku::ZeroDivisionError if denominator.zero?

      value = left.value % denominator
      remainder = BigDecimal(value.to_s, Float::DIG + 1)
      if remainder.zero?
        relevant = !left.tangent.empty? || !right.tangent.empty?
        mark(:non_differentiable, 'modulo is non-differentiable when the remainder is zero') if relevant
        return Dual.new(value: value, tangent: {}, kink: true)
      end

      quotient_floor = (BigDecimal(left.value.to_s, Float::DIG + 1) / denominator).floor
      tangent = merge_tangents(
        left.tangent,
        scale(right.tangent, -quotient_floor)
      )
      Dual.new(value: value, tangent: tangent, kink: left.kink || right.kink)
    end

    def evaluate_power(node)
      base = numeric_dual(evaluate(node.left))
      exponent = numeric_dual(evaluate(node.right))
      x = base.value
      y = exponent.value
      value = x ** y
      validate_arithmetic_result(value, x, y)

      if x == 0
        mark(:non_differentiable, 'power is non-differentiable at a zero base') if !base.tangent.empty? || !exponent.tangent.empty?
        return Dual.new(value: value, tangent: {}, kink: true)
      end

      if x < 0
        if y.is_a?(Integer) && exponent.tangent.empty?
          tangent = scale(base.tangent, y * (x ** (y - 1)))
          return Dual.new(value: value, tangent: tangent, kink: base.kink)
        end

        mark(:unknown_derivative, 'power derivative with respect to a variable exponent is undefined for negative bases')
        return Dual.new(value: value, tangent: {}, kink: true)
      end

      log_x = Math.log(x.to_f)
      tangent = merge_tangents(
        scale(base.tangent, y * (x ** (y - 1))),
        scale(exponent.tangent, value * log_x)
      )
      Dual.new(value: value, tangent: tangent, kink: base.kink || exponent.kink)
    end

    def evaluate_less_than(node); comparator(node, :<); end
    def evaluate_less_than_or_equal(node); comparator(node, :<=); end
    def evaluate_greater_than(node); comparator(node, :>); end
    def evaluate_greater_than_or_equal(node); comparator(node, :>=); end
    def evaluate_equal(node); comparator(node, :==); end
    def evaluate_not_equal(node); comparator(node, :!=); end

    def comparator(node, operator)
      left = evaluate(node.left)
      right = evaluate(node.right)
      kink = left.value == right.value
      relevant = !left.tangent.empty? || !right.tangent.empty? || left.kink || right.kink
      mark(:non_differentiable, 'comparison is on a non-differentiable boundary') if kink && relevant
      boolean_dual(
        left.value.public_send(operator, right.value),
        {},
        kink: kink || left.kink || right.kink
      )
    end

    def evaluate_and(node)
      left = evaluate(node.left)
      return boolean_dual(false, left.tangent, kink: left.kink) unless left.value

      right = evaluate(node.right)
      boolean_dual(
        left.value && right.value,
        merge_tangents(left.tangent, right.tangent),
        kink: left.kink || right.kink
      )
    end

    def evaluate_or(node)
      left = evaluate(node.left)
      return boolean_dual(true, left.tangent, kink: left.kink) if left.value

      right = evaluate(node.right)
      boolean_dual(
        left.value || right.value,
        merge_tangents(left.tangent, right.tangent),
        kink: left.kink || right.kink
      )
    end

    def evaluate_if(node)
      predicate = evaluate(node.predicate)
      chosen = predicate.value ? evaluate(node.left) : evaluate(node.right)
      if predicate.kink
        mark(:non_differentiable, 'IF predicate is on a non-differentiable boundary')
        chosen = Dual.new(value: chosen.value, tangent: {}, kink: true)
      end
      chosen
    end

    def evaluate_not(node)
      argument = evaluate(node.args.first)
      boolean_dual(!argument.value, argument.tangent, kink: argument.kink)
    end

    def evaluate_xor(node)
      arguments = node.args.map { |argument| evaluate(argument) }
      boolean_dual(
        arguments.one? { |argument| argument.value == true },
        merge_tangents(*arguments.map(&:tangent)),
        kink: arguments.any?(&:kink)
      )
    end

    def evaluate_function(node)
      arguments = node.args.map { |argument| evaluate(argument) }
      name = function_name(node)

      case name
      when 'abs'
        return built_in_abs(arguments.first)
      when 'round', 'rounddown', 'roundup'
        return built_in_round(name, arguments)
      when 'sum', 'avg', 'mul', 'max', 'min'
        return built_in_aggregate(name, arguments)
      when 'not'
        return evaluate_not(node)
      when 'xor'
        return evaluate_xor(node)
      end

      value = begin
        node.class.implementation.call(*arguments.map(&:value))
      rescue Dentaku::Error
        raise
      rescue StandardError => error
        failure(:custom_function_error, "#{name}() failed: #{error.message}")
      end

      derivative_rule = node.class.respond_to?(:derivative) ? node.class.derivative : nil
      unless derivative_rule
        if arguments.any? { |argument| !argument.tangent.empty? }
          mark(:unknown_derivative, "derivative for #{name}() is not defined")
          return Dual.new(value: value, tangent: {}, kink: false)
        end

        return constant(value)
      end

      apply_derivative(name, value, derivative_rule, arguments)
    end

    def evaluate_ruby_math(node)
      arguments = node.args.flatten.map { |argument| numeric_dual(evaluate(argument)) }
      name = function_name(node).to_sym
      value = begin
        Math.public_send(name, *arguments.map(&:value))
      rescue Math::DomainError
        raise Dentaku::MathDomainError.new(name, arguments.map(&:value))
      end

      return constant(value) unless value.is_a?(Numeric)

      rule = RUBY_MATH_DERIVATIVES.fetch(name, nil)
      unless rule
        mark(:unknown_derivative, "derivative for #{name}() is not defined") if arguments.any? { |argument| !argument.tangent.empty? }
        return Dual.new(value: value, tangent: {}, kink: false)
      end

      partials = instance_exec(arguments.map(&:value), &rule)
      dual = combine_partials(name, value, arguments, partials)
      if !dual.tangent.empty? && dual.tangent.values.any? { |partial| partial.respond_to?(:finite?) && !partial.finite? }
        mark(:non_differentiable, "#{name}() is non-differentiable at this input")
        dual.tangent = {}
        dual.kink = true
      end
      dual
    rescue StandardError => error
      raise unless error.is_a?(Math::DomainError) || error.is_a?(::FloatDomainError)

      mark(:non_differentiable, "#{name}() is non-differentiable at this input")
      Dual.new(value: value, tangent: {}, kink: true)
    end

    def function_name(node)
      node.class.name.to_s.split('::').last.to_s.downcase
    end

    def built_in_abs(argument)
      argument = numeric_dual(argument)
      if argument.value.zero?
        mark(:non_differentiable, 'ABS is non-differentiable at zero') unless argument.tangent.empty?
        return Dual.new(value: argument.value.abs, tangent: {}, kink: true)
      end

      factor = argument.value.negative? ? -1 : 1
      Dual.new(
        value: argument.value.abs,
        tangent: scale(argument.tangent, factor),
        kink: argument.kink
      )
    end

    def built_in_round(name, arguments)
      number = numeric_dual(arguments.first)
      places = arguments[1] ? numeric_dual(arguments[1]).value.to_i : 0
      tens = 10.0**places
      value = case name
              when 'round'
                number.value.round(places)
              when 'rounddown'
                scaled = number.value * tens
                result = scaled.floor / tens
                places <= 0 ? result.to_i : result
              else
                scaled = number.value * tens
                result = scaled.ceil / tens
                places <= 0 ? result.to_i : result
              end
      scaled = number.value * tens
      boundary = case name
                 when 'round'
                   scaled.respond_to?(:round) && (scaled - scaled.round).abs < Float::EPSILON
                 when 'rounddown'
                   scaled.respond_to?(:floor) && (scaled - scaled.floor).abs < Float::EPSILON
                 else
                   scaled.respond_to?(:ceil) && (scaled.ceil - scaled).abs < Float::EPSILON
                 end
      if boundary && !number.tangent.empty?
        mark(:non_differentiable, "#{name.upcase} is non-differentiable at a rounding boundary")
        return Dual.new(value: value, tangent: {}, kink: true)
      end

      Dual.new(value: value, tangent: {}, kink: number.kink)
    end

    def built_in_aggregate(name, arguments)
      values = arguments.map(&:value).flatten
      numeric_values = values.map { |item| numeric_value(item) }
      case name
      when 'sum'
        dual = combine_flattened(arguments) { 1 }
        value = numeric_values.reduce(0, :+)
      when 'avg'
        dual = combine_flattened(arguments) { 1.0 / values.length }
        value = numeric_values.reduce(0, :+) / BigDecimal(values.length)
      when 'mul'
        value = numeric_values.reduce(1, :*)
        dual = combine_flattened(arguments) { |item| value / item }
      when 'max'
        value = numeric_values.max
        winners = values.each_index.select { |index| values[index] == value }
        dual = combine_flattened(arguments) { |item| item == value ? 1 : 0 }
        mark(:non_differentiable, 'MAX is non-differentiable when inputs tie') if winners.length > 1 && !dual.tangent.empty?
      when 'min'
        value = numeric_values.min
        winners = values.each_index.select { |index| values[index] == value }
        dual = combine_flattened(arguments) { |item| item == value ? 1 : 0 }
        mark(:non_differentiable, 'MIN is non-differentiable when inputs tie') if winners.length > 1 && !dual.tangent.empty?
      end
      dual.value = value
      dual
    end

    def combine_flattened(arguments, &factor)
      tangent = {}
      values = []
      arguments.each do |argument|
        items = argument.value.is_a?(Array) ? argument.value : [argument.value]
        numeric_items = items.map { |item| numeric_value(item) }
        values.concat(numeric_items)
        factors = numeric_items.map { |item| factor.call(item) }
        if argument.value.is_a?(Array)
          aggregate = argument.partials&.each_with_index&.each_with_object({}) do |(partial, index), merged|
            coefficient = factors[index]
            next if coefficient.nil? || coefficient.zero?

            merged.merge!(scale(partial.tangent, coefficient)) { |_, old, new| old + new }
          end
          tangent = merge_tangents(tangent, aggregate || {})
        else
          tangent = merge_tangents(tangent, scale(argument.tangent, factors.first || 0))
        end
      end
      Dual.new(value: nil, tangent: tangent, kink: arguments.any?(&:kink))
    end

    def apply_derivative(name, value, rule, arguments)
      partials = begin
        if rule.arity == 1 && arguments.length == 1
          single_partial = rule.call(arguments.first.value)
          single_partial.is_a?(Array) ? single_partial : [single_partial]
        elsif !rule.arity.negative? && rule.arity != 1
          rule.call(*arguments.map(&:value))
        else
          rule.call(arguments.map(&:value))
        end
      rescue StandardError => error
        mark(:custom_function_error, "derivative for #{name}() failed: #{error.message}")
        return Dual.new(value: value, tangent: {}, kink: true)
      end

      combine_partials(name, value, arguments, partials)
    end

    def combine_partials(name, value, arguments, partials)
      partials = Array(partials)
      unless partials.length == arguments.length && partials.all? { |partial| partial.nil? || partial.is_a?(Numeric) || partial.is_a?(Array) }
        mark(:custom_function_error, "derivative for #{name}() returned an invalid value")
        return Dual.new(value: value, tangent: {}, kink: true)
      end

      tangent = {}
      arguments.each_with_index do |argument, index|
        partial = partials[index]
        next if partial.nil?

        if partial.is_a?(Array)
          unless argument.value.is_a?(Array) && partial.length == argument.value.length
            mark(:custom_function_error, "derivative for #{name}() returned an invalid array shape")
            return Dual.new(value: value, tangent: {}, kink: true)
          end
          partials_for_argument = argument.partials || []
          partial.each_with_index do |coefficient, index|
            child = partials_for_argument[index]
            next if coefficient.nil? || coefficient.zero? || child.nil?

            tangent = merge_tangents(tangent, scale(child.tangent, coefficient))
          end
          next
        end
        tangent = merge_tangents(tangent, scale(argument.tangent, partial))
      end

      Dual.new(value: value, tangent: tangent, kink: arguments.any?(&:kink))
    end

    def failure(status, message)
      mark(status, message)
      raise GradientEvaluationError.new(status, message)
    end

    RUBY_MATH_DERIVATIVES = {
      sqrt: ->(x) { [(0.5 / Math.sqrt(x[0]))] },
      cbrt: ->(x) { [(1.0 / (3.0 * (x[0] ** 2) ** (1.0 / 3.0)))] },
      exp: ->(x) { [Math.exp(x[0])] },
      expm1: ->(x) { [Math.exp(x[0])] },
      log: ->(x) { x.length == 1 ? [1.0 / x[0]] : [1.0 / (x[0] * Math.log(x[1])), -Math.log(x[0]) / (x[1] * Math.log(x[1]) ** 2)] },
      log2: ->(x) { [1.0 / (x[0] * Math.log(2))] },
      log10: ->(x) { [1.0 / (x[0] * Math.log(10))] },
      log1p: ->(x) { [1.0 / (x[0] + 1.0)] },
      sin: ->(x) { [Math.cos(x[0])] },
      cos: ->(x) { [-Math.sin(x[0])] },
      tan: ->(x) { [1.0 / Math.cos(x[0]) ** 2] },
      sinh: ->(x) { [Math.cosh(x[0])] },
      cosh: ->(x) { [Math.sinh(x[0])] },
      tanh: ->(x) { [1.0 / Math.cosh(x[0]) ** 2] },
      asin: ->(x) { [1.0 / Math.sqrt(1.0 - x[0] ** 2)] },
      acos: ->(x) { [-1.0 / Math.sqrt(1.0 - x[0] ** 2)] },
      atan: ->(x) { [1.0 / (1.0 + x[0] ** 2)] },
      asinh: ->(x) { [1.0 / Math.sqrt(x[0] ** 2 + 1.0)] },
      acosh: ->(x) { [1.0 / Math.sqrt(x[0] ** 2 - 1.0)] },
      atanh: ->(x) { [1.0 / (1.0 - x[0] ** 2)] },
      erf: ->(x) { [2.0 / Math.sqrt(Math::PI) * Math.exp(-(x[0] ** 2))] },
      erfc: ->(x) { [-2.0 / Math.sqrt(Math::PI) * Math.exp(-(x[0] ** 2))] },
      hypot: ->(x) { c = Math.hypot(x[0], x[1]); [x[0] / c, x[1] / c] },
      atan2: ->(x) { [x[1] / (x[0] ** 2 + x[1] ** 2), -x[0] / (x[0] ** 2 + x[1] ** 2)] },
      ldexp: ->(x) { [2.0 ** x[1], 0] }
    }.freeze
  end
end
