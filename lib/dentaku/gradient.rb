require_relative 'exceptions'
require 'bigdecimal'

module Dentaku
  # Forward-mode automatic differentiation over a parsed expression.
  #
  # Calculator#evaluate_with_gradient! parses and evaluates an expression
  # exactly once, tracking next to every intermediate value its gradient
  # with respect to the requested variables. Only the branches that normal
  # evaluation would execute are visited: the untaken side of an IF is
  # never evaluated, so functions there are not called and errors there
  # do not surface.
  module Gradient
    # The outcome of a gradient evaluation: the plain value of the
    # expression (identical to what #evaluate! returns) plus a hash of
    # partial derivatives keyed by (case-standardized) variable name.
    class Result
      attr_reader :value, :gradient

      def initialize(value, gradient)
        @value = value
        @gradient = gradient
      end

      def [](variable)
        gradient[variable]
      end
    end

    # intermediate value during evaluation: the plain value plus the
    # gradient of that value as a {variable => partial} hash
    Trace = Struct.new(:value, :grad)

    class Evaluator
      def initialize(memory, variables)
        @memory = memory
        @variables = variables
      end

      def evaluate(node)
        case node
        when AST::Literal
          Trace.new(node.value, {})
        when AST::Identifier
          identifier(node)
        when AST::Negation
          negation(node)
        when AST::Arithmetic
          arithmetic(node)
        when AST::Comparator
          comparator(node)
        when AST::Combinator
          combinator(node)
        when AST::If
          branch(node)
        when AST::Function
          function(node)
        else
          # arrays, bitwise operations, case statements, string functions,
          # ... anything without gradient semantics evaluates plainly and
          # contributes no gradient
          Trace.new(node.value(@memory), {})
        end
      end

      private

      def identifier(node)
        name = node.identifier
        unless @memory.key?(name)
          raise UnboundVariableError.new([name]),
                "no value provided for variables: #{name}"
        end

        stored = @memory[name]
        if @variables.include?(name)
          Trace.new(raw_value(stored), { name => 1 })
        else
          case stored
          when AST::Node then evaluate(stored)
          when Proc then Trace.new(stored.call, {})
          else Trace.new(stored, {})
          end
        end
      end

      def raw_value(stored)
        case stored
        when AST::Node then stored.value(@memory)
        when Proc then stored.call
        else stored
        end
      end

      def negation(node)
        trace = evaluate(node.node)
        numeric = numeric(trace.value)
        return Trace.new(node.value(@memory), {}) if numeric.nil?

        Trace.new(numeric * -1, scale(trace.grad, -1))
      end

      def arithmetic(node)
        if node.is_a?(AST::Percentage)
          trace = evaluate(node.left)
          numeric = numeric(trace.value)
          return Trace.new(node.value(@memory), {}) if numeric.nil?

          return Trace.new(numeric * 0.01, scale(trace.grad, 0.01))
        end

        left = evaluate(node.left)
        right = evaluate(node.right)
        l = numeric(left.value)
        r = numeric(right.value)

        # non-numeric operands (dates, durations, ...) evaluate exactly as
        # they normally would and carry no gradient
        return Trace.new(node.value(@memory), {}) if l.nil? || r.nil?

        case node
        when AST::Addition
          Trace.new(calculate(node, l, r), add(left.grad, right.grad))
        when AST::Subtraction
          Trace.new(calculate(node, l, r), subtract(left.grad, right.grad))
        when AST::Multiplication
          Trace.new(calculate(node, l, r),
                    add(scale(left.grad, r), scale(right.grad, l)))
        when AST::Division
          division(node, left, right, l, r)
        when AST::Modulo
          modulo(node, left, right, l, r)
        when AST::Exponentiation
          exponentiation(node, left, right, l, r)
        end
      end

      def division(node, left, right, l, r)
        divisor = decimal(r)
        raise Dentaku::ZeroDivisionError if divisor.zero?

        value = l / divisor
        # d(l/r) = (l' * r - l * r') / r^2; quo keeps integer gradients
        # exact instead of truncating them to zero
        numerator = subtract(scale(left.grad, r), scale(right.grad, l))
        denominator = r * r
        gradient = {}
        numerator.each { |var, amount| gradient[var] = amount.quo(denominator) }

        Trace.new(value, gradient)
      end

      def modulo(node, left, right, l, r)
        divisor = decimal(r)
        raise Dentaku::ZeroDivisionError if divisor.zero?

        value = l % divisor
        if (l % r).zero? && (nonzero?(left.grad) || nonzero?(right.grad))
          raise Dentaku::NonDifferentiableError.for(:modulo_boundary)
        end

        # l % r = l - r * floor(l / r)
        gradient = subtract(left.grad, scale(right.grad, (l / r).floor))
        Trace.new(value, gradient)
      end

      def exponentiation(node, left, right, l, r)
        value = calculate(node, l, r)

        if nonzero?(right.grad)
          # d(u^v) = u^v * (v' * ln(u) + v * u' / u), defined for u > 0
          raise Dentaku::NonDifferentiableError.for(:power_indeterminate) if l <= 0

          gradient = add(scale(left.grad, value * r / l),
                         scale(right.grad, value * Math.log(l.to_f)))
          return Trace.new(value, gradient)
        end

        return Trace.new(value, {}) unless nonzero?(left.grad)

        # constant exponent: d(u^r) = r * u^(r-1) * u'
        coefficient =
          if l.zero?
            case
            when r > 1 then 0
            when r == 1 then 1
            else raise Dentaku::NonDifferentiableError.for(:power_indeterminate)
            end
          else
            r * l**(r - 1)
          end

        Trace.new(value, scale(left.grad, coefficient))
      end

      def comparator(node)
        left = evaluate(node.left)
        right = evaluate(node.right)
        l = comparator_cast(left.value)
        r = comparator_cast(right.value)

        if l == r && (nonzero?(left.grad) || nonzero?(right.grad))
          raise Dentaku::NonDifferentiableError.for(:comparison_boundary, operator: node.operator)
        end

        validate_comparable(node, l)
        validate_comparable(node, r)

        value = begin
          l.public_send(node.operator, r)
        rescue ::ArgumentError, ::TypeError => e
          raise Dentaku::ArgumentError.for(:incompatible_type, actual: r, expected: l.class), e.message
        end

        Trace.new(value, {})
      end

      def combinator(node)
        left = evaluate(node.left)

        case node
        when AST::And
          return Trace.new(left.value, {}) unless left.value
        when AST::Or
          return Trace.new(left.value, {}) if left.value
        end

        right = evaluate(node.right)
        Trace.new(right.value, {})
      end

      # only the taken branch is evaluated: functions on the other side
      # are never called and errors there never surface
      def branch(node)
        predicate = evaluate(node.predicate)
        evaluate(predicate.value ? node.left : node.right)
      end

      def function(node)
        arg_traces = node.args.map { |arg| evaluate(arg) }
        values = arg_traces.map(&:value)
        gradients = arg_traces.map(&:grad)
        rule = node.class.derivative

        if rule
          # compute the value first so domain errors (e.g. sqrt of a
          # negative) raise exactly as they do in normal evaluation
          value = function_value(node, values)
          partials = rule.call(values, gradients)
          gradient = partials.is_a?(Hash) ? partials : chain(partials, gradients, node)
          Trace.new(value, gradient)
        elsif node.type == :numeric
          raise Dentaku::UnsupportedDerivativeError.new(function_name(node))
        else
          Trace.new(node.value(@memory), {})
        end
      end

      def function_value(node, values)
        klass = node.class

        if klass.respond_to?(:implementation) && klass.implementation
          klass.implementation.call(*values)
        elsif node.is_a?(AST::RubyMath)
          klass.call(*values.flatten.map { |v| Dentaku::NumericParser.ensure_numeric!(v) })
        else
          node.value(@memory)
        end
      end

      def function_name(node)
        node.class.name
      end

      # gradient of f(args) from the function's partial derivatives and
      # the argument gradients: sum over i of partial_i * grad(arg_i)
      def chain(partials, gradients, node)
        result = {}
        partials.each_with_index do |partial, index|
          next if partial.nil? || (partial.is_a?(::Numeric) && partial.zero?)

          gradients[index].each do |variable, amount|
            next if amount.zero?

            if partial.is_a?(::Numeric) && partial.respond_to?(:finite?) && !partial.finite?
              raise Dentaku::NonDifferentiableError.for(:unbounded_derivative,
                                                        function_name: function_name(node))
            end

            result[variable] = (result[variable] || 0) + partial * amount
          end
        end
        result
      end

      # mirrors Arithmetic#calculate: the same result and the same
      # exceptions for overflow and invalid operations
      def calculate(node, l, r)
        result = l.public_send(node.operator, r)
        return result unless nonfinite?(result)
        return result if nonfinite?(l) || nonfinite?(r)

        raise Dentaku::ArgumentError.for(:invalid_value, actual: r),
              "Result of #{l} #{node.operator} #{r} is not a finite number"
      rescue Dentaku::Error
        raise
      rescue ::ArgumentError, ::RangeError, ::FloatDomainError => e
        raise Dentaku::ArgumentError.for(:invalid_value, actual: r), e.message
      end

      def nonfinite?(value)
        value.is_a?(::Numeric) && value.respond_to?(:finite?) && !value.finite?
      end

      def numeric(value)
        return value if value.is_a?(::Numeric)
        return Dentaku::NumericParser.ensure_numeric(value) if value.is_a?(::String)

        nil
      end

      def decimal(value)
        BigDecimal(value.to_s, Float::DIG + 1)
      rescue StandardError
        value
      end

      def comparator_cast(value)
        return value unless value.is_a?(::String)

        Dentaku::NumericParser.parse_string(value) || value
      end

      def validate_comparable(node, value)
        return if value.respond_to?(node.operator)

        raise Dentaku::ArgumentError.for(:invalid_operator, operation: node.class, operator: node.operator)
      end

      def nonzero?(gradient)
        gradient.values.any? { |amount| amount != 0 }
      end

      def add(left, right)
        left.merge(right) { |_var, a, b| a + b }
      end

      def subtract(left, right)
        add(left, scale(right, -1))
      end

      def scale(gradient, factor)
        return {} if factor == 0 || gradient.empty?

        gradient.transform_values { |amount| amount * factor }
      end
    end
  end
end
