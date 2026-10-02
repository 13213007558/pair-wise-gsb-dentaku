require_relative '../function'
require_relative '../../exceptions'

Dentaku::AST::Function.register(:round, :numeric, lambda { |numeric, places = 0|
  Dentaku::NumericParser.ensure_numeric!(numeric).round(Dentaku::NumericParser.ensure_numeric!(places || 0).to_i)
}, derivative: lambda { |values, gradients|
  numeric = Dentaku::NumericParser.ensure_numeric!(values[0])
  places = Dentaku::NumericParser.ensure_numeric!(values[1] || 0).to_i
  scaled = numeric * (10**places)

  if (scaled % 1) == 0.5 && gradients[0].values.any? { |gradient| gradient != 0 }
    raise Dentaku::NonDifferentiableError.for(:round_kink, function_name: 'ROUND')
  end

  [0, 0]
})
