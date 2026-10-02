# import all functions from Ruby's Math module
require_relative '../function'

module Dentaku
  module AST
    class RubyMath < Function
      def self.[](method)
        klass_name = method.to_s.capitalize
        klass = const_set(klass_name , Class.new(self))
        klass.implement(method)
        const_get(klass_name)
      end

      def self.implement(method)
        @name = method
        @implementation = Math.method(method)
      end

      # Ruby documents Module#name as a String (or nil for anonymous
      # classes), so expose one even though the function is registered
      # under a Symbol
      def self.name
        @name.to_s
      end

      def self.arity
        @implementation.arity < 0 ? nil : @implementation.arity
      end

      def self.min_param_count
        @implementation.parameters.select { |type, _name| type == :req }.count
      end

      def self.max_param_count
        @implementation.parameters.select { |type, _name| type == :rest }.any? ? Float::INFINITY : @implementation.parameters.count
      end

      def self.call(*args)
        @implementation.call(*args)
      rescue Math::DomainError => _e
        raise Dentaku::MathDomainError.new(name, args)
      end

      def value(context = {})
        args = @args.flatten.map { |a|Dentaku::NumericParser.ensure_numeric!(a.value(context)) }
        self.class.call(*args)
      end

      ARRAY_RETURN_TYPES = [:frexp, :lgamma].freeze

      def type
        ARRAY_RETURN_TYPES.include?(@name) ? :array : :numeric
      end
    end
  end
end

Math.methods(false).each do |method|
  Dentaku::AST::Function.register_class(method, Dentaku::AST::RubyMath[method])
end

# derivative rules for the differentiable Math functions, consumed by
# Dentaku::Gradient; each rule receives (values, gradients) for the
# evaluated arguments and returns one partial derivative per argument.
# Functions without a rule (gamma, frexp, ...) raise
# Dentaku::UnsupportedDerivativeError when differentiation reaches them.
module Dentaku
  module AST
    class RubyMath < Function
      DERIVATIVES = {
        sin:   ->(values, _gradients) { [Math.cos(values[0])] },
        cos:   ->(values, _gradients) { [-Math.sin(values[0])] },
        tan:   ->(values, _gradients) { [1.0 / Math.cos(values[0])**2] },
        asin:  ->(values, _gradients) { [1.0 / Math.sqrt(1 - values[0]**2)] },
        acos:  ->(values, _gradients) { [-1.0 / Math.sqrt(1 - values[0]**2)] },
        atan:  ->(values, _gradients) { [1.0 / (1 + values[0]**2)] },
        sinh:  ->(values, _gradients) { [Math.cosh(values[0])] },
        cosh:  ->(values, _gradients) { [Math.sinh(values[0])] },
        tanh:  ->(values, _gradients) { [1.0 / Math.cosh(values[0])**2] },
        asinh: ->(values, _gradients) { [1.0 / Math.sqrt(values[0]**2 + 1)] },
        acosh: ->(values, _gradients) { [1.0 / (Math.sqrt(values[0] - 1) * Math.sqrt(values[0] + 1))] },
        atanh: ->(values, _gradients) { [1.0 / (1 - values[0]**2)] },
        exp:   ->(values, _gradients) { [Math.exp(values[0])] },
        log:   lambda { |values, _gradients|
          if values.size == 2
            [1.0 / (values[0] * Math.log(values[1])),
             -Math.log(values[0]) / (values[1] * Math.log(values[1])**2)]
          else
            [1.0 / values[0]]
          end
        },
        log2:  ->(values, _gradients) { [1.0 / (values[0] * Math::LN2)] },
        log10: ->(values, _gradients) { [1.0 / (values[0] * Math::LN10)] },
        sqrt:  ->(values, _gradients) { [0.5 / Math.sqrt(values[0])] },
        cbrt:  ->(values, _gradients) { [1.0 / (3.0 * values[0]**(2.0 / 3.0))] },
        erf:   ->(values, _gradients) { [2.0 / Math.sqrt(Math::PI) * Math.exp(-values[0]**2)] },
        erfc:  ->(values, _gradients) { [-2.0 / Math.sqrt(Math::PI) * Math.exp(-values[0]**2)] },
        hypot: lambda { |values, _gradients|
          norm = Math.hypot(*values)
          values.map { |value| value / norm }
        },
      }.freeze
    end
  end
end

Dentaku::AST::RubyMath::DERIVATIVES.each do |method, rule|
  Dentaku::AST::Function.register_derivative(method, rule)
end
