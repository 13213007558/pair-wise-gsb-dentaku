require 'bigdecimal'
require 'dentaku'

describe Dentaku::DecimalContext do
  let(:calculator) { Dentaku::Calculator.new }

  def evaluate(expression, context, data = {})
    calculator.evaluate!(expression, data, { decimal_context: context })
  end

  def untrapped_context(precision:, rounding: :half_up)
    described_class.new(
      precision: precision,
      rounding: rounding,
      traps: { division_by_zero: false, overflow: false, inexact: false }
    )
  end

  it 'keeps repeated nonterminating division scoped to one execution' do
    context = untrapped_context(precision: 6)
    result = evaluate('1 / 3', context)

    expect(result).to eq(BigDecimal('0.333333'))
    expect(result.signals).to eq(%i[inexact])
    expect(evaluate('1 + 1', context)).to eq(2)
  end

  it 'preserves exact cancellation without reporting an inexact signal' do
    context = untrapped_context(precision: 6)
    result = evaluate('1.0005 - 0.0005', context)

    expect(result).to eq(BigDecimal('1'))
    expect(result.signals).to eq([])
  end

  it 'applies the configured mode to a negative rounding midpoint' do
    half_up = untrapped_context(precision: 6, rounding: :half_up)
    half_even = untrapped_context(precision: 6, rounding: :half_even)

    expect(evaluate('round(-1.235, 2)', half_up)).to eq(BigDecimal('-1.24'))
    expect(evaluate('round(-1.235, 2)', half_even)).to eq(BigDecimal('-1.24'))
  end

  it 'rounds negative midpoints differently for half-up and half-even values' do
    half_up = untrapped_context(precision: 6, rounding: :half_up)
    half_even = untrapped_context(precision: 6, rounding: :half_even)

    expect(evaluate('round(-1.245, 2)', half_up)).to eq(BigDecimal('-1.25'))
    expect(evaluate('round(-1.245, 2)', half_even)).to eq(BigDecimal('-1.24'))
  end

  it 'passes the same context through nested functions' do
    context = untrapped_context(precision: 4)
    result = evaluate('roundup(round(1 / 3, 2), 1)', context)

    expect(result).to eq(BigDecimal('0.4'))
    expect(result.signals).to eq(%i[inexact])
  end

  it 'marks exact integer powers with more significant digits than the context' do
    context = untrapped_context(precision: 4)
    result = evaluate('12 ^ 5', context)

    expect(result).to eq(BigDecimal('248800'))
    expect(result.signals).to eq(%i[inexact])
  end

  it 'still evaluates nonnumeric control functions in decimal context' do
    context = untrapped_context(precision: 6)
    result = evaluate('AND(true, 1 / 3 < 1)', context)

    expect(result.value).to be(true)
    expect(result.signals).to eq(%i[inexact])
  end

  it 'keeps signals from two interleaved precisions separate' do
    precision_six = untrapped_context(precision: 6)
    precision_four = untrapped_context(precision: 4)
    results = []

    results << evaluate('1 / 3', precision_six)
    results << evaluate('1 / 3', precision_four)
    results << evaluate('1.0005 - 0.0005', precision_six)
    results << evaluate('1.0005 - 0.0005', precision_four)

    expect(results.map { |result| result.to_s('F') })
      .to eq(%w[0.333333 0.3333 1.0 1.001])
    expect(results.map(&:signals)).to eq([
      %i[inexact],
      %i[inexact],
      [],
      %i[inexact]
    ])
  end

  it 'records a division-by-zero signal instead of raising when untrapped' do
    context = untrapped_context(precision: 6)
    result = evaluate('1 / zero', context, zero: BigDecimal(0))

    expect(result).to eq(BigDecimal('Infinity'))
    expect(result.signals).to eq(%i[division_by_zero])
  end

  it 'records division by zero for a zero base with a huge negative exponent' do
    context = untrapped_context(precision: 6)
    result = evaluate('0 ^ exponent', context, exponent: -1_000_000)

    expect(result).to eq(BigDecimal('-Infinity'))
    expect(result.signals).to eq(%i[division_by_zero])
  end

  it 'raises a division-by-zero exception when trapped' do
    context = described_class.new(precision: 6)

    expect { evaluate('1 / 0', context) }.to raise_error(Dentaku::ZeroDivisionError) do |error|
      expect(error.signals).to eq(%i[division_by_zero])
    end
  end

  it 'records an overflow signal for power operations when untrapped' do
    context = untrapped_context(precision: 6)
    result = evaluate('2 ^ exponent', context, exponent: 1_000_000)

    expect(result).to eq(BigDecimal('Infinity'))
    expect(result.signals).to eq(%i[overflow])
  end

  it 'keeps unit bases exact for huge integer exponents' do
    context = untrapped_context(precision: 6)
    result = evaluate('1 ^ exponent', context, exponent: 1_000_000)

    expect(result).to eq(BigDecimal('1'))
    expect(result.signals).to eq([])
  end

  it 'supports integer powers of negative bases' do
    context = untrapped_context(precision: 6)
    result = evaluate('(-2) ^ 2', context)

    expect(result).to eq(BigDecimal('4'))
    expect(result.signals).to eq([])
  end

  it 'raises when an overflow trap is enabled' do
    context = described_class.new(
      precision: 6,
      traps: { division_by_zero: false, overflow: true, inexact: false }
    )

    expect { evaluate('2 ^ 1000000', context) }
      .to raise_error(Dentaku::DecimalOverflowError) do |error|
      expect(error.signals).to eq(%i[overflow])
    end
  end

  it 'raises immediately for an inexact result when trapped' do
    context = described_class.new(precision: 6)

    expect { evaluate('1 / 3', context) }
      .to raise_error(Dentaku::DecimalInexactError) do |error|
      expect(error.signals).to eq(%i[inexact])
    end
  end

  it 'raises when an input literal cannot fit a trapped context' do
    context = described_class.new(precision: 4)

    expect { evaluate('1.23456', context) }
      .to raise_error(Dentaku::DecimalInexactError)
  end

  it 'coerces string, integer and BigDecimal inputs with the same precision' do
    context = untrapped_context(precision: 6)
    result = evaluate('string_literal + integer_value + big_decimal_value + 1.2345',
                      context,
                      string_literal: '1.2345',
                      integer_value: 12,
                      big_decimal_value: BigDecimal('1.2345'))

    expect(result).to eq(BigDecimal('15.7035'))
    expect(result.signals).to eq([])
  end

  it 'does not record signals from an unevaluated conditional branch' do
    context = untrapped_context(precision: 6)
    result = evaluate('IF(true, 1, 1 / 0)', context)

    expect(result).to eq(1)
    expect(result.signals).to eq([])
  end

  it 'rejects functions that do not provide exact decimal semantics' do
    context = described_class.new(precision: 6)

    expect { evaluate('sqrt(2)', context) }
      .to raise_error(Dentaku::DecimalUnsupportedError, /sqrt.*exact decimal semantics/i)
  end

  it 'rejects Float input because it cannot represent an exact decimal' do
    context = described_class.new(precision: 6)

    expect { evaluate('x + 1', context, x: 1.5) }
      .to raise_error(Dentaku::ArgumentError, /not supported in decimal context/i)
  end

  it 'still validates supported aggregate functions in decimal context' do
    context = described_class.new(precision: 6)

    expect { evaluate('AVG(x)', context, x: []) }
      .to raise_error(Dentaku::ArgumentError)
  end

  it 'allows custom functions to opt in to decimal execution' do
    calculator.add_function(:double, :numeric,
                           ->(execution, value) { execution.multiply(value, 2) },
                           decimal: true)
    context = described_class.new(precision: 6)

    expect(evaluate('double(2.5)', context)).to eq(BigDecimal('5.0'))
  end

  it 'allows custom decimal functions with variadic expression arguments' do
    calculator.add_function(:decimal_sum, :numeric,
                           ->(execution, *values) { execution.sum(values) },
                           decimal: true)
    context = described_class.new(precision: 6)

    expect(evaluate('decimal_sum(1.25, 2.25)', context)).to eq(BigDecimal('3.5'))
  end

  it 'keeps calculator-level decimal context for bulk solutions' do
    decimal_calculator = Dentaku::Calculator.new(
      decimal_context: described_class.new(precision: 6, traps: { inexact: false })
    )
    result = decimal_calculator.solve!(a: '1 / 3', b: 'a + 2')

    expect(result[:a]).to eq(BigDecimal('0.333333'))
    expect(result[:b]).to eq(BigDecimal('2.33333'))
    expect(result[:a].signals).to eq(%i[inexact])
    expect(result[:b].signals).to eq(%i[inexact])
  end

  it 'does not send overridden built-in function names to built-in decimal dispatch' do
    calculator.add_function(:round, :numeric, ->(value) { value.to_f })
    context = described_class.new(precision: 6)

    expect { evaluate('round(2.5)', context) }
      .to raise_error(Dentaku::DecimalUnsupportedError, /round/i)
  end

  it 'rejects custom numeric functions that do not opt in to decimal execution' do
    calculator.add_function(:floatish, :numeric, ->(value) { value.to_f })
    context = described_class.new(precision: 6)

    expect { evaluate('floatish(2.5)', context) }
      .to raise_error(Dentaku::DecimalUnsupportedError, /floatish/i)
  end

  it 'leaves process-wide BigDecimal settings unchanged' do
    original_rounding = BigDecimal.mode(BigDecimal::ROUND_MODE)
    original_limit = BigDecimal.limit
    described_class.new(precision: 4, rounding: :half_even)

    expect(BigDecimal.mode(BigDecimal::ROUND_MODE)).to eq(original_rounding)
    expect(BigDecimal.limit).to eq(original_limit)
  end

  it 'does not alter default evaluation' do
    expect(calculator.evaluate!('1/3')).to eq(BigDecimal('1') / BigDecimal('3'))
  end
end
