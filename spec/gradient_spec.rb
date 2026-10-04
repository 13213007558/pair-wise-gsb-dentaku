require 'spec_helper'
require 'dentaku'

describe Dentaku::Calculator, '#gradient!' do
  let(:calculator) { described_class.new }

  def finite_difference(expression, variables, key, epsilon = 1e-6)
    numerator = calculator.evaluate!(
      expression,
      variables.merge(key => variables[key].to_f + epsilon)
    ).to_f - calculator.evaluate!(
      expression,
      variables.merge(key => variables[key].to_f - epsilon)
    ).to_f
    numerator / (2.0 * epsilon)
  end

  it 'differentiates arithmetic and merges repeated variables into one component' do
    result = calculator.gradient!('x * x + 3 * y - z / 2', x: 2, y: 4, z: 10)

    expect(result.value).to eq(11)
    expect(result.gradient.keys).to contain_exactly('x', 'y', 'z')
    expect(result.gradient).to eq('x' => 4, 'y' => 3, 'z' => -0.5)
    expect(result.status).to eq(:ok)
  end

  it 'counts a variable appearing three times once' do
    result = calculator.gradient!('x + x + x', x: 2)

    expect(result.value).to eq(6)
    expect(result.gradient).to eq('x' => 3)
    expect(result.gradient.length).to eq(1)
  end

  it 'evaluates a shared formula once and accumulates every reference' do
    calls = 0
    calculator.add_function(
      :square,
      :numeric,
      ->(x) { calls += 1; x * x },
      derivative: ->(x) { 2 * x }
    )
    calculator.store_formula('shared', 'square(x)')

    result = calculator.gradient!('shared * 2 + shared', x: 3)

    expect(calls).to eq(1)
    expect(result.value).to eq(27)
    expect(result.gradient).to eq('x' => 18)
  end

  it 'differentiates piecewise formulas only through the selected branch' do
    result = calculator.gradient!('IF(x > 0, y * 2, z * 3)', x: 1, y: 4, z: 5)

    expect(result.value).to eq(8)
    expect(result.gradient).to eq('x' => 0, 'y' => 2, 'z' => 0)

    result = calculator.gradient!('IF(x > 0, y * 2, z * 3)', x: -1, y: 4, z: 5)

    expect(result.value).to eq(15)
    expect(result.gradient).to eq('x' => 0, 'y' => 0, 'z' => 3)
  end

  it 'supports custom two-variable functions and does not call them for perturbation' do
    calls = 0
    calculator.add_function(
      :biased_power,
      :numeric,
      ->(x, y) { calls += 1; x ** y },
      derivative: ->(x, y, result) {
        [result * y / x, result * Math.log(x)]
      }
    )

    result = calculator.gradient!('biased_power(x, y)', x: 2, y: 3)

    expect(result.value).to eq(8)
    expect(result.gradient.fetch('x')).to be_within(1e-12).of(12)
    expect(result.gradient.fetch('y')).to be_within(1e-12).of(8 * Math.log(2))
    expect(calls).to eq(1)
  end

  it 'accepts derivative rules through add_functions options' do
    calculator.add_functions([
      [:triple, :numeric, ->(x) { 3 * x }, nil, { derivative: ->(_x) { 3 } }]
    ])

    expect(calculator.gradient!('triple(x)', x: 2).gradient).to eq('x' => 3)
  end

  it 'differentiates built-in two-variable Math functions' do
    result = calculator.gradient!('HYPOT(x, y) + ATAN2(y, x) + LOG(x, y)', x: 3, y: 4)

    analytic_x = (3.0 / 5) - (4.0 / 25) + (1.0 / (3.0 * Math.log(4)))
    analytic_y = 4.0 / 5 + 3.0 / 25 - Math.log(3) / (4.0 * Math.log(4)**2)

    expect(result.gradient.fetch('x')).to be_within(1e-12).of(analytic_x)
    expect(result.gradient.fetch('y')).to be_within(1e-12).of(analytic_y)
  end

  it 'differentiates variadic numeric helpers and CASE on the selected branch' do
    calculator.store_formula('piece', 'CASE tier WHEN 1 THEN x * 2 WHEN 2 THEN x * 3 ELSE x END')

    result = calculator.gradient!('SUM(x, y, z) + (x * y) - AVG(x, y) + piece',
                                 x: 2, y: 3, z: 4, tier: 2)

    expect(result.value).to eq(9 + 6 - 2.5 + 6)
    expect(result.gradient.fetch('x')).to eq(1 + 3 - 0.5 + 3)
    expect(result.gradient.fetch('y')).to eq(1 + 2 - 0.5)
    expect(result.gradient.fetch('z')).to eq(1)
  end

  it 'treats a non-numeric result as non-differentiable' do
    result = calculator.gradient("'not a number'", {})

    expect(result.status).to eq(:non_differentiable)
    expect(result.value).to eq('not a number')
  end

  it 'agrees with central differences away from singularities' do
    expression = 'x^3 / y + SQRT((x^2 + y^2)) + exp((x * 0.1)) + sin(y) + log(x) + cos(y)'
    variables = { 'x' => 3, 'y' => 2 }
    result = calculator.gradient!(expression, variables)

    expect(result.gradient.fetch('x')).to be_within(1e-6).of(
      finite_difference(expression, variables, 'x')
    )
    expect(result.gradient.fetch('y')).to be_within(1e-6).of(
      finite_difference(expression, variables, 'y')
    )
  end

  it 'matches central differences for common differentiable unary functions' do
    cases = {
      'sqrt(x)' => 4.0,
      'cbrt(x)' => 8.0,
      'exp(x)' => 0.5,
      'log(x)' => 2.0,
      'log2(x)' => 4.0,
      'log10(x)' => 5.0,
      'sin(x)' => 0.7,
      'cos(x)' => 0.7,
      'tan(x)' => 0.5,
      'asin(x)' => 0.4,
      'acos(x)' => 0.4,
      'atan(x)' => 1.2,
      'sinh(x)' => 0.6,
      'cosh(x)' => 0.6,
      'tanh(x)' => 0.6,
      'asinh(x)' => 1.0,
      'acosh(x)' => 2.0,
      'atanh(x)' => 0.4,
      'erf(x)' => 0.7,
      'erfc(x)' => 0.7
    }

    cases.each do |expression, value|
      variables = { 'x' => value }
      result = calculator.gradient!(expression, variables)

      expect(result.gradient.fetch('x')).to be_within(1e-5).of(
        finite_difference(expression, variables, 'x')
      ), expression
    end
  end

  it 'reports a non-differentiable point without inventing a finite gradient' do
    result = calculator.gradient('abs(x)', x: 0)

    expect(result.status).to eq(:non_differentiable)
    expect(result.value).to eq(0)
    expect(result.gradient).to eq('x' => 0)
    expect(result.error).to be_a(Dentaku::GradientError)
  end

  it 'reports modulo at an integer boundary as non-differentiable' do
    result = calculator.gradient('x % y', x: 6, y: 3)

    expect(result.status).to eq(:non_differentiable)
    expect(result.value).to eq(0)
  end

  it 'raises the non-differentiable status from the bang entry point' do
    expect { calculator.gradient!('abs(x)', x: 0) }
      .to raise_error(Dentaku::GradientError) { |error|
        expect(error.status).to eq(:non_differentiable)
      }
  end

  it 'reports an unknown derivative for a custom function without a derivative rule' do
    calculator.add_function(:plain, :numeric, ->(x) { x * 2 })

    result = calculator.gradient('plain(x)', x: 1)

    expect(result.status).to eq(:unknown_derivative)
    expect(result.value).to eq(2)
    expect(result.gradient).to eq('x' => 0)
  end

  it 'reports a custom derivative failure explicitly' do
    calculator.add_function(
      :broken_derivative,
      :numeric,
      ->(x) { x },
      derivative: ->(_x) { raise 'derivative unavailable' }
    )

    result = calculator.gradient('broken_derivative(x)', x: 1)

    expect(result.status).to eq(:function_error)
    expect(result.value).to eq(1)
    expect(result.error.message).to include('derivative unavailable')
  end

  it 'does not evaluate unknown or failing derivatives on an unselected IF branch' do
    calculator.add_function(:plain, :numeric, ->(x) { x * 2 })

    result = calculator.gradient!('IF(x > 0, y, plain(x))', x: 1, y: 2)

    expect(result.value).to eq(2)
    expect(result.gradient).to eq('x' => 0, 'y' => 1)
  end

  it 'does not call an unknown custom function on an unselected branch' do
    calls = 0
    calculator.add_function(:unused, :numeric, ->(x) { calls += 1; x })

    result = calculator.gradient!('IF(x > 0, y, unused(x))', x: 1, y: 2)

    expect(calls).to eq(0)
    expect(result.value).to eq(2)
  end

  it 'does not require a derivative for a function only used in a guard' do
    calculator.add_function(:guard, :numeric, ->(x) { x > 0 })

    result = calculator.gradient!('IF(guard(x), y, z)', x: 1, y: 2, z: 3)

    expect(result.status).to eq(:ok)
    expect(result.gradient).to eq('x' => 0, 'y' => 1, 'z' => 0)
  end

  it 'evaluates a volatile predicate once and follows the branch it selects' do
    calls = 0
    calculator.add_function(
      :volatile_guard,
      :numeric,
      ->(x) { calls += 1; x > 0 },
      volatile: true,
      derivative: ->(_x) { 0 }
    )

    result = calculator.gradient!('IF(volatile_guard(x), y, z)', x: 1, y: 2, z: 3)

    expect(calls).to eq(1)
    expect(result.gradient).to eq('x' => 0, 'y' => 1, 'z' => 0)
  end

  it 'returns a failure result from the non-bang entry point for evaluation errors' do
    result = calculator.gradient('1 / x', x: 0)

    expect(result.status).to eq(:function_error)
    expect(result.error).to be_a(Dentaku::ZeroDivisionError)
  end
end
