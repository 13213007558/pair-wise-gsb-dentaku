require_relative '../function'
require_relative '../../exceptions'

Dentaku::AST::Function.register(:abs, :numeric, lambda { |numeric|
  Dentaku::NumericParser.ensure_numeric!(numeric).abs
}, derivative: lambda { |values, gradients|
  numeric = Dentaku::NumericParser.ensure_numeric!(values[0])

  if numeric.zero? && gradients[0].values.any? { |gradient| gradient != 0 }
    raise Dentaku::NonDifferentiableError.for(:abs_zero)
  end

  [numeric <=> 0]
})
