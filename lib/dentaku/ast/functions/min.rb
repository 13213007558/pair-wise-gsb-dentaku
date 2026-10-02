require_relative '../function'

Dentaku::AST::Function.register(
  :min,
  :numeric,
  ->(*args) { args.flatten.map { |arg| Dentaku::NumericParser.ensure_numeric!(arg) }.min },
  decimal: true,
  decimal_implementation: Dentaku::DecimalFunctions.method(:min)
)
