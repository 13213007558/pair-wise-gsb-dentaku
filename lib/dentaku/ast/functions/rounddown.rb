require_relative '../function'
require_relative '../../exceptions'

Dentaku::AST::Function.register(:rounddown, :numeric, lambda { |numeric, precision = 0|
  precision = Dentaku::NumericParser.ensure_numeric!(precision || 0).to_i
  tens = 10.0**precision
  result = (Dentaku::NumericParser.ensure_numeric!(numeric) * tens).floor / tens
  precision <= 0 ? result.to_i : result
}, derivative: lambda { |values, gradients|
  numeric = Dentaku::NumericParser.ensure_numeric!(values[0])
  precision = Dentaku::NumericParser.ensure_numeric!(values[1] || 0).to_i
  scaled = numeric * (10**precision)

  if (scaled % 1).zero? && gradients[0].values.any? { |gradient| gradient != 0 }
    raise Dentaku::NonDifferentiableError.for(:round_kink, function_name: 'ROUNDDOWN')
  end

  [0, 0]
})
