require 'dentaku/exceptions'

module Dentaku
  module GradientRules
    module_function

    def derivative(function, arguments, result)
      custom = custom_derivative(function, arguments, result)
      return custom if custom

      name = function.name.to_s.downcase
      values = arguments.flatten

      case name
      when 'abs' then scalar(values) { |x| x.zero? ? non_differentiable!('ABS at zero') : x <=> 0 }
      when 'sqrt' then unary(values) { |x| 1.0 / (2.0 * Math.sqrt(x.to_f)) }
      when 'cbrt' then unary(values) { |x| x.zero? ? non_differentiable!('CBRT at zero') : 1.0 / (3.0 * Math.cbrt(x.to_f)**2) }
      when 'exp' then unary(values) { |x| Math.exp(x.to_f) }
      when 'expm1' then unary(values) { |x| Math.exp(x.to_f) }
      when 'log' then log(values)
      when 'log2' then unary(values) { |x| 1.0 / (x.to_f * Math.log(2)) }
      when 'log10' then unary(values) { |x| 1.0 / (x.to_f * Math.log(10)) }
      when 'log1p' then unary(values) { |x| 1.0 / (1.0 + x.to_f) }
      when 'sin' then unary(values) { |x| Math.cos(x.to_f) }
      when 'cos' then unary(values) { |x| -Math.sin(x.to_f) }
      when 'tan' then unary(values) { |x| 1.0 / Math.cos(x.to_f)**2 }
      when 'asin' then unary(values) { |x| 1.0 / Math.sqrt(1.0 - x.to_f**2) }
      when 'acos' then unary(values) { |x| -1.0 / Math.sqrt(1.0 - x.to_f**2) }
      when 'atan' then unary(values) { |x| 1.0 / (1.0 + x.to_f**2) }
      when 'sinh' then unary(values) { |x| Math.cosh(x.to_f) }
      when 'cosh' then unary(values) { |x| Math.sinh(x.to_f) }
      when 'tanh' then unary(values) { |x| 1.0 - Math.tanh(x.to_f)**2 }
      when 'asinh' then unary(values) { |x| 1.0 / Math.sqrt(1.0 + x.to_f**2) }
      when 'acosh' then unary(values) { |x| 1.0 / Math.sqrt(x.to_f**2 - 1.0) }
      when 'atanh' then unary(values) { |x| 1.0 / (1.0 - x.to_f**2) }
      when 'erf' then unary(values) { |x| 2.0 / Math.sqrt(Math::PI) * Math.exp(-x.to_f**2) }
      when 'erfc' then unary(values) { |x| -2.0 / Math.sqrt(Math::PI) * Math.exp(-x.to_f**2) }
      when 'gamma', 'lgamma' then unknown_derivative!(name.upcase)
      when 'frexp' then unknown_derivative!('FREXP')
      when 'hypot' then hypot(values, result)
      when 'atan2' then atan2(values)
      when 'max', 'min' then extreme(name, values)
      when 'and', 'or', 'xor', 'not' then values.map { 0 }
      when 'sum' then values.map { 1 }
      when 'avg' then values.map { 1.0 / values.length }
      when 'mul' then mul(values)
      when 'ldexp' then ldexp(values)
      else unknown_derivative!(function.name)
      end
    end

    def custom_derivative(function, arguments, result)
      return nil unless function.respond_to?(:derivative) && function.derivative

      partials = begin
        call_derivative(function.derivative, arguments, result)
      rescue GradientError
        raise
      rescue StandardError => error
        function_error!(function.name, error)
      end

      partials = [partials] unless partials.is_a?(Array)
      unless partials.length == arguments.length && partials.all? { |partial| partial.is_a?(Numeric) }
        function_error!(function.name, 'derivative must return one numeric value per argument')
      end

      partials
    end

    def call_derivative(derivative, arguments, result)
      if derivative.lambda? && derivative.arity >= 0 && derivative.arity <= arguments.length
        return derivative.call(*arguments)
      elsif derivative.lambda? && derivative.arity.negative?
        if derivative.arity == -1 || arguments.length >= derivative.arity.abs - 1
          return derivative.call(*arguments)
        else
          return derivative.call(*arguments, result)
        end
      else
        derivative.call(*arguments, result)
      end
    end

    def unary(values)
      arity!(values, 1)
      [yield(values.first)]
    end

    def scalar(values)
      unary(values) { |value| yield(value) }
    end

    def log(values)
      arity!(values, 1..2)
      x = values.first.to_f
      if values.length == 1
        [1.0 / x]
      else
        base = values.last.to_f
        log_base = Math.log(base)
        [1.0 / (x * log_base), -Math.log(x) / (base * log_base**2)]
      end
    end

    def hypot(values, result)
      arity!(values, 2)
      x, y = values.map(&:to_f)
      value = result.to_f
      non_differentiable!('HYPOT at zero') if value.zero?
      [x / value, y / value]
    end

    def atan2(values)
      arity!(values, 2)
      y, x = values.map(&:to_f)
      denominator = x**2 + y**2
      non_differentiable!('ATAN2 at zero') if denominator.zero?
      [x / denominator, -y / denominator]
    end

    def extreme(name, values)
      target = name == 'max' ? values.max : values.min
      winners = values.each_index.select { |index| values[index] == target }
      non_differentiable!("#{name.upcase} tie") if winners.length > 1
      values.each_index.map { |index| index == winners.first ? 1 : 0 }
    end

    def mul(values)
      values.each_index.map do |index|
        values.each_with_index.reduce(1) do |product, (value, other_index)|
          index == other_index ? product : product * value
        end
      end
    end

    def ldexp(values)
      arity!(values, 2)
      x, exponent = values
      scale = 2.0**exponent.to_f
      [scale, x.to_f * scale * Math.log(2)]
    end

    def arity!(values, expected)
      return if expected === values.length

      function_error!('built-in Math function', "expected #{expected}, got #{values.length}")
    end

    def non_differentiable!(reason)
      raise GradientError.new(:non_differentiable, reason)
    end

    def unknown_derivative!(name)
      raise GradientError.new(:unknown_derivative, name.to_s)
    end

    def function_error!(name, error)
      reason = error.is_a?(StandardError) ? error.message : error.to_s
      raise GradientError.new(:function_error, "#{name}: #{reason}")
    end
  end
end
