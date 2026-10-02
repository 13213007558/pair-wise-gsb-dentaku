require_relative '../function'
require_relative '../../exceptions'

Dentaku::AST::Function.register(:max, :numeric, ->(*args) {
  args.flatten.map { |arg| Dentaku::NumericParser.ensure_numeric!(arg) }.max
}, derivative: lambda { |values, gradients|
  numerics = values.map { |value| Dentaku::NumericParser.ensure_numeric!(value) }
  target = numerics.max
  tied = numerics.each_index.select { |index| numerics[index] == target }

  if tied.size > 1 && tied.map { |index| gradients[index] }.uniq.size > 1
    raise Dentaku::NonDifferentiableError.for(:min_max_tie, function_name: 'MAX')
  end

  partials = Array.new(numerics.size, 0)
  partials[tied.first] = 1
  partials
})
