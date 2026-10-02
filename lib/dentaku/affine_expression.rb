require 'bigdecimal'
require 'dentaku/exceptions'

module Dentaku
  class AffineExpression
    attr_reader :coefficients, :constant

    def self.variable(name)
      new(name => 1)
    end

    def self.constant(value)
      new({}, value)
    end

    def self.cast(value)
      return value if value.is_a?(self)

      constant(exact(value))
    end

    def self.exact(value)
      case value
      when Rational
        value
      when Integer
        value.to_r
      when BigDecimal
        value.to_r
      when Float
        value.to_r
      when Numeric
        Rational(value.to_s)
      else
        raise NonlinearExpressionError
      end
    end

    def initialize(coefficients = {}, constant = 0)
      @coefficients = coefficients.each_with_object({}) do |(name, value), h|
        exact_value = self.class.exact(value)
        h[name.to_s] = exact_value unless exact_value.zero?
      end
      @constant = self.class.exact(constant)
    end

    def variables
      coefficients.keys
    end

    def constant?
      coefficients.empty?
    end

    def +(other)
      other = self.class.cast(other)
      coefficients = merge_coefficients(other) { |left, right| left + right }
      self.class.new(coefficients, constant + other.constant)
    end

    def -(other)
      self + (-self.class.cast(other))
    end

    def -@
      scale(-1)
    end

    def *(other)
      other = self.class.cast(other)

      if constant?
        other.scale(constant).with_constant(other.constant * constant)
      elsif other.constant?
        scale(other.constant)
      else
        raise NonlinearExpressionError
      end
    end

    def /(other)
      other = self.class.cast(other)
      raise NonlinearExpressionError unless other.constant?
      raise Dentaku::ZeroDivisionError if other.constant.zero?

      scale(Rational(1) / other.constant)
    end

    def **(other)
      other = self.class.cast(other)
      if constant? && other.constant?
        exponent = other.constant
        raise NonlinearExpressionError unless exponent.denominator == 1

        return self.class.constant(constant ** exponent)
      end

      raise NonlinearExpressionError unless other.constant == 1

      self
    end

    def %(other)
      other = self.class.cast(other)
      if constant? && other.constant?
        return self.class.constant(constant % other.constant)
      end

      raise NonlinearExpressionError
    end

    def scale(factor)
      factor = self.class.exact(factor)
      scaled = coefficients.transform_values { |value| value * factor }
      self.class.new(scaled, constant * factor)
    end

    def with_constant(value)
      self.class.new(coefficients, value)
    end

    def substitute(values)
      values = values.each_with_object({}) do |(key, value), h|
        h[normalize(key)] = self.class.cast(value)
      end

      coefficients.reduce(self.class.constant(constant)) do |result, (name, coefficient)|
        normalized_name = normalize(name)
        if values.key?(normalized_name)
          result + values.fetch(normalized_name).scale(coefficient)
        else
          result + self.class.variable(normalized_name).scale(coefficient)
        end
      end
    end

    def ==(other)
      return false unless other.is_a?(self.class)

      coefficients == other.coefficients && constant == other.constant
    end
    alias_method :eql?, :==

    def hash
      [coefficients, constant].hash
    end

    def inspect
      terms = coefficients.map { |name, coefficient| "#{coefficient}*#{name}" }
      terms << constant.to_s unless constant.zero?
      terms.empty? ? '0' : terms.join(' + ')
    end
    alias_method :to_s, :inspect

    private

    def normalize(name)
      name.to_s
    end

    def merge_coefficients(other)
      (coefficients.keys + other.coefficients.keys).uniq.each_with_object({}) do |name, h|
        result = yield(coefficients.fetch(name, 0), other.coefficients.fetch(name, 0))
        h[name] = result unless result.zero?
      end
    end
  end

  class NonlinearExpressionError < BaseError
  end

  class NonlinearEquationError < BaseError
    attr_reader :formula

    def initialize(formula)
      @formula = formula
      super('formula is not a numeric affine dependency: %s' % formula)
    end
  end
end
