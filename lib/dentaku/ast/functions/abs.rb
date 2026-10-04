require_relative '../function'
require_relative '../../exceptions'

Dentaku::AST::Function.register(:abs, :numeric, lambda { |numeric|
  Dentaku::NumericParser.ensure_numeric!(numeric).abs
}, derivative: lambda { |numeric|
  value = Dentaku::NumericParser.ensure_numeric!(numeric)
  raise Dentaku::GradientError.new(:non_differentiable, 'ABS at zero') if value.zero?

  value <=> 0
})
