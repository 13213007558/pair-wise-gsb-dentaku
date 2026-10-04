require_relative '../function'

implementation = lambda do |*args|
  flatten_args = args.flatten
  if flatten_args.empty?
    raise Dentaku::ArgumentError.for(
      :too_few_arguments,
      function_name: 'AVG', expected: 1.., actual: 0
    )
  end

  flatten_args.map { |arg| Dentaku::NumericParser.ensure_numeric!(arg) }.reduce(0, :+)
end

Dentaku::AST::Function.register(
  :avg,
  :numeric,
  ->(*args) { implementation.call(*args) / BigDecimal(args.flatten.length) },
  derivative: ->(*args) { args.flatten.map { 1.0 / args.flatten.length } }
)
