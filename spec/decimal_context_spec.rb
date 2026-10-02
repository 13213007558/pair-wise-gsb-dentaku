require 'spec_helper'
require 'dentaku'

describe Dentaku::DecimalContext do
  let(:calculator) { Dentaku::Calculator.new }

  def recording_context(precision: 6, rounding_mode: :half_even)
    described_class.new(
      precision: precision,
      rounding_mode: rounding_mode,
      division_by_zero: :record,
      overflow: :record,
      inexact: :record
    )
  end

  it 'rounds one third using context precision and records inexactness' do
    context = recording_context(precision: 6)

    expect(calculator.evaluate!('1 / 3', {}, { decimal_context: context })).to eq(BigDecimal('0.333333'))
    expect(calculator.decimal_signals).to eq(%i[inexact])
  end

  it 'preserves cancellation results when all significant digits fit' do
    context = recording_context(precision: 8)

    expect(calculator.evaluate!('1.00001 - 1', {}, { decimal_context: context })).to eq(BigDecimal('0.00001'))
    expect(calculator.decimal_signals).to eq([])
  end

  it 'records inexactness when cancellation drops below context precision' do
    context = recording_context(precision: 3)

    expect(calculator.evaluate!('1 / 3 - 0.333', {}, { decimal_context: context })).to eq(BigDecimal(0))
    expect(calculator.decimal_signals).to eq(%i[inexact])
  end

  it 'uses the configured rounding mode at negative midpoints' do
    half_even = recording_context(precision: 2, rounding_mode: :half_even)
    half_up = recording_context(precision: 2, rounding_mode: :half_up)

    expect(calculator.evaluate!('ROUND(-2.5)', {}, { decimal_context: half_even })).to eq(BigDecimal(-2))
    expect(calculator.evaluate!('ROUND(-2.5)', {}, { decimal_context: half_up })).to eq(BigDecimal(-3))
  end

  it 'applies the same convention to literals, variables and nested functions' do
    context = recording_context(precision: 10)

    result = calculator.evaluate!(
      'ROUND(SUM(1, literal, variable, 2 ^ 2), 4)',
      { 'literal' => '3.25', variable: BigDecimal('4.75') },
      { decimal_context: context }
    )

    expect(result).to be_a(BigDecimal)
    expect(result).to eq(BigDecimal('13.0'))
    expect(calculator.decimal_signals).to eq([])
  end

  it 'accepts exact integer, BigDecimal and string decimal inputs' do
    context = recording_context(precision: 10)

    result = calculator.evaluate!(
      'integer + big_decimal + string_decimal',
      {
        integer: 1,
        big_decimal: BigDecimal('2.25'),
        string_decimal: '3.50'
      },
      { decimal_context: context }
    )

    expect(result).to eq(BigDecimal('6.75'))
    expect(result).to be_a(BigDecimal)
    expect(calculator.decimal_signals).to eq([])
  end

  it 'rejects binary floating-point inputs because they are not exact decimals' do
    context = recording_context(precision: 10)

    expect {
      calculator.evaluate!('x + 1', { x: 1.2 }, { decimal_context: context })
    }.to raise_error(Dentaku::ArgumentError, /not supported in decimal calculations/)
  end

  it 'interleaves calculations with different precision and rounding contexts' do
    precision_two = recording_context(precision: 2, rounding_mode: :half_down)
    precision_eight = recording_context(precision: 8, rounding_mode: :half_up)

    first = calculator.evaluate!('1 / 3', {}, { decimal_context: precision_two })
    second = calculator.evaluate!('1 / 3', {}, { decimal_context: precision_eight })
    third = calculator.evaluate!('1 / 3', {}, { decimal_context: precision_two })

    expect(first).to eq(BigDecimal('0.33'))
    expect(second).to eq(BigDecimal('0.33333333'))
    expect(third).to eq(BigDecimal('0.33'))
    expect(precision_two.signals).to eq(%i[inexact])
    expect(precision_eight.signals).to eq(%i[inexact])
  end

  it 'keeps separate contexts isolated across concurrent calculations' do
    precision_two = described_class.new(precision: 2, inexact: :record)
    precision_twelve = described_class.new(precision: 12, inexact: :record)
    calculator_two = Dentaku::Calculator.new
    calculator_twelve = Dentaku::Calculator.new
    threads = [
      Thread.new { 100.times { calculator_two.evaluate!('1 / 3', {}, { decimal_context: precision_two }) } },
      Thread.new { 100.times { calculator_twelve.evaluate!('1 / 3', {}, { decimal_context: precision_twelve }) } }
    ]

    threads.each(&:join)

    expect(precision_two.signals).to eq(%i[inexact])
    expect(precision_twelve.signals).to eq(%i[inexact])
    expect(calculator_two.evaluate!('1 / 3', {}, { decimal_context: precision_two })).to eq(BigDecimal('0.33'))
    result_twelve = calculator_twelve.evaluate!('1 / 3', {}, { decimal_context: precision_twelve })
    expect(result_twelve).to eq(BigDecimal('0.333333333333'))
  end

  it 'keeps signals from only operations actually executed' do
    context = recording_context(precision: 6)

    skipped = calculator.evaluate!(
      'IF(condition, 1 / 3, 2)', { 'condition' => false }, { decimal_context: context }
    )
    expect(skipped).to eq(BigDecimal(2))
    expect(calculator.decimal_signals).to eq([])

    executed = calculator.evaluate!(
      'IF(condition, 1 / 3, 2)', { 'condition' => true }, { decimal_context: context }
    )
    expect(executed).to eq(BigDecimal('0.333333'))
    expect(calculator.decimal_signals).to eq(%i[inexact])
  end

  it 'records division by zero instead of raising when configured' do
    context = recording_context(precision: 6)

    expect(calculator.evaluate!('1 / 0', {}, { decimal_context: context })).to eq(BigDecimal::INFINITY)
    expect(calculator.decimal_signals).to eq(%i[division_by_zero])
  end

  it 'records overflow instead of raising when configured' do
    context = recording_context(precision: 2)

    expect(calculator.evaluate!('10 ^ 1000001', {}, { decimal_context: context })).to eq(BigDecimal::INFINITY)
    expect(calculator.decimal_signals).to eq(%i[overflow])
  end

  it 'raises by default for exactness failures, division by zero and overflow' do
    context = described_class.new(precision: 6)

    expect { calculator.evaluate!('1 / 3', {}, { decimal_context: context }) }
      .to raise_error(Dentaku::InexactDecimalResultError)
    expect { calculator.evaluate!('1 / 0', {}, { decimal_context: context }) }
      .to raise_error(Dentaku::ZeroDivisionError)
    expect { calculator.evaluate!('10 ^ 1000001', {}, { decimal_context: context }) }
      .to raise_error(Dentaku::DecimalOverflowError)
  end

  it 'rejects functions that cannot promise exact decimal semantics' do
    context = recording_context(precision: 6)

    expect {
      calculator.evaluate!('SQRT(2)', {}, { decimal_context: context })
    }.to raise_error(Dentaku::DecimalUnsupportedFunctionError, /SQRT.*exact decimal/)
  end

  it 'rejects other numeric helpers that calculate through binary floats' do
    context = recording_context(precision: 6)

    expect {
      calculator.evaluate!('INTERCEPT(ys, xs)', { xs: [1, 2], ys: [2, 3] }, { decimal_context: context })
    }.to raise_error(Dentaku::DecimalUnsupportedFunctionError, /INTERCEPT.*exact decimal/)
  end

  it 'rejects custom numeric functions that do not opt into decimal semantics' do
    calculator.add_function(:double, :numeric, ->(value) { value * 2 })
    context = recording_context(precision: 6)

    expect {
      calculator.evaluate!('DOUBLE(1)', {}, { decimal_context: context })
    }.to raise_error(Dentaku::DecimalUnsupportedFunctionError, /DOUBLE.*exact decimal/)
  end

  it 'allows custom functions that supply a decimal implementation' do
    calculator.add_function(
      :double,
      :numeric,
      ->(value) { value * 2.0 },
      decimal: true,
      decimal_implementation: ->(decimal_context, value) { decimal_context.multiply(value, 2) }
    )
    context = recording_context(precision: 6)

    expect(calculator.evaluate!('DOUBLE(1.25)', {}, { decimal_context: context })).to eq(BigDecimal('2.5'))
    expect(calculator.decimal_signals).to eq([])
  end

  it 'uses a decimal context configured on the calculator' do
    context = described_class.new(precision: 4, inexact: :record)
    configured = Dentaku::Calculator.new(decimal_context: context)

    expect(configured.evaluate!('1 / 3')).to eq(BigDecimal('0.3333'))
    expect(configured.decimal_signals).to eq(%i[inexact])
  end

  it 'applies a calculator-configured decimal context to bulk solutions' do
    context = described_class.new(precision: 5, inexact: :record)
    configured = Dentaku::Calculator.new(decimal_context: context)

    result = configured.solve!(a: '1 / 3', b: 'a + 0.1')

    expect(result[:a]).to eq(BigDecimal('0.33333'))
    expect(result[:b]).to eq(BigDecimal('0.43333'))
    expect(configured.decimal_signals).to eq(%i[inexact])
  end

  it 'does not use or modify BigDecimal process-wide settings' do
    context = recording_context(precision: 3)
    BigDecimal.save_exception_mode do
      BigDecimal.save_limit do
        BigDecimal.save_rounding_mode do
          BigDecimal.mode(BigDecimal::EXCEPTION_ALL, false)
          BigDecimal.limit(20)
          BigDecimal.mode(BigDecimal::ROUND_MODE, BigDecimal::ROUND_DOWN)

          expect(calculator.evaluate!('1 / 3', {}, { decimal_context: context })).to eq(BigDecimal('0.333'))
          expect(calculator.decimal_signals).to eq(%i[inexact])
        end
      end
    end
  end

  it 'keeps default calculations unchanged' do
    expect(calculator.evaluate!('1 / 2')).to eq(0.5)
    expect(calculator.evaluate!('1 + 2')).to eq(3)
    expect(calculator.decimal_signals).to eq([])
  end
end
