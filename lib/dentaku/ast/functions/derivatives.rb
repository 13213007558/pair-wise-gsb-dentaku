require_relative '../function'

module Dentaku
  module MathDerivatives
    def self.non_differentiable(function_name, point)
      Dentaku::DifferentiationError.for(
        :non_differentiable,
        name: function_name.to_s.upcase,
        point: point
      )
    end
  end

  TWO_OVER_SQRT_PI = 2.0 / Math.sqrt(Math::PI)

  MATH_DERIVATIVES = {
    acos: ->(x) {
      raise MathDerivatives.non_differentiable(:acos, "x = #{x}") if x.abs == 1
      -1.0 / Math.sqrt(1.0 - x**2)
    },
    acosh: ->(x) {
      raise MathDerivatives.non_differentiable(:acosh, "x = #{x}") if x == 1
      1.0 / Math.sqrt(x**2 - 1.0)
    },
    asin: ->(x) {
      raise MathDerivatives.non_differentiable(:asin, "x = #{x}") if x.abs == 1
      1.0 / Math.sqrt(1.0 - x**2)
    },
    asinh: ->(x) { 1.0 / Math.sqrt(x**2 + 1.0) },
    atan: ->(x) { 1.0 / (1.0 + x**2) },
    atan2: ->(y, x) {
      denominator = x**2 + y**2
      [x.to_f / denominator, -y.to_f / denominator]
    },
    atanh: ->(x) {
      raise MathDerivatives.non_differentiable(:atanh, "x = #{x}") if x.abs == 1
      1.0 / (1.0 - x**2)
    },
    cbrt: ->(x) {
      raise MathDerivatives.non_differentiable(:cbrt, 'x = 0') if x.zero?
      1.0 / (3.0 * Math.cbrt(x)**2)
    },
    cos: ->(x) { -Math.sin(x) },
    cosh: ->(x) { Math.sinh(x) },
    erf: ->(x) { TWO_OVER_SQRT_PI * Math.exp(-x**2) },
    erfc: ->(x) { -TWO_OVER_SQRT_PI * Math.exp(-x**2) },
    exp: ->(x) { Math.exp(x) },
    hypot: ->(x, y) {
      h = Math.hypot(x, y)
      [x.to_f / h, y.to_f / h]
    },
    log: ->(x, base = nil) {
      if base.nil?
        1.0 / x
      else
        natural = Math.log(base)
        [1.0 / (x * natural), -Math.log(x) / (base * natural**2)]
      end
    },
    log10: ->(x) { 1.0 / (x * Math.log(10)) },
    log2: ->(x) { 1.0 / (x * Math.log(2)) },
    sin: ->(x) { Math.cos(x) },
    sinh: ->(x) { Math.cosh(x) },
    sqrt: ->(x) {
      raise MathDerivatives.non_differentiable(:sqrt, 'x = 0') if x.zero?
      1.0 / (2.0 * Math.sqrt(x))
    },
    tan: ->(x) { 1.0 / Math.cos(x)**2 },
    tanh: ->(x) { 1.0 / Math.cosh(x)**2 }
  }.freeze

  module AST
    MATH_DERIVATIVES.each do |name, rule|
      Function.register_derivative(name, rule)
    end
  end
end
