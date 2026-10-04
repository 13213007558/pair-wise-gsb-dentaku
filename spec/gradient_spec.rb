require 'spec_helper'
require 'dentaku'

describe Dentaku::Calculator, 'gradient evaluation' do
  subject(:calculator) { described_class.new }

  def finite_difference(expression, data, variable, epsilon = 1e-6)
    positive = data.merge(variable => data.fetch(variable) + epsilon)
    negative = data.merge(variable => data.fetch(variable) - epsilon)
    (calculator.evaluate!(expression, positive) - calculator.evaluate!(expression, negative)) / (2 * epsilon)
  end

  def expect_gradient_matches_finite_difference(expression, data, variables = data.keys)
    result = calculator.evaluate_with_gradient!(expression, data)
    expected = calculator.evaluate!(expression, data)

    expect(result.result).to eq(expected)
    variables.each do |variable|
      expect(result.gradient[variable.to_s]).to be_within(1e-5).of(finite_difference(expression, data, variable))
    end
  end

  it 'evaluates arithmetic and merges repeated variables into one component' do
    expression = 'x * x + 2 * x + 1'
    result = calculator.evaluate_with_gradient!(expression, x: 3)

    expect(result.status).to eq(:ok)
    expect(result.result).to eq(16)
    expect(result.gradient).to eq('x' => 8)
    expect(result.gradient.keys).to eq(['x'])
  end

  it 'supports shared subexpressions through stored formulas' do
    calculator.store_formula(:shared, 'x + 1')
    expression = 'shared * shared + shared'
    result = calculator.evaluate_with_gradient!(expression, x: 2)

    expect(result.result).to eq(12)
    expect(result.gradient).to eq('x' => 7)
    expect(result.gradient.keys).to eq(['x'])
  end

  it 'propagates gradients only through the executed IF branch' do
    active = calculator.evaluate_with_gradient!('IF(x > 0, x * x, missing * missing)', x: 3)
    inactive = calculator.evaluate_with_gradient!('IF(x < 0, unprovided_branch, 2 * missing)', x: 3, missing: 5)

    expect(active.result).to eq(9)
    expect(active.gradient).to eq('x' => 6)
    expect(inactive.result).to eq(10)
    expect(inactive.gradient).to eq('missing' => 2)
  end

  it 'reports an IF predicate at a non-differentiable boundary' do
    result = calculator.evaluate_with_gradient('IF(x > 0, x, -x)', x: 0)

    expect(result.status).to eq(:non_differentiable)
    expect(result.result).to eq(0)
    expect(result.gradient).to eq({})
    expect(result.reasons.first.status).to eq(:non_differentiable)
  end

  it 'cross-validates piecewise cost away from boundaries' do
    expression = 'IF(units <= threshold, rate1 * units, rate2 * units + (rate1 - rate2) * threshold)'
    data = { units: 12, threshold: 10, rate1: 2, rate2: 3 }
    result = calculator.evaluate_with_gradient!(expression, data)

    expect(result.result).to eq(26)
    expect(result.gradient).to eq(
      'units' => 3,
      'threshold' => -1,
      'rate1' => 10,
      'rate2' => 2
    )
    %i[units threshold rate1 rate2].each do |variable|
      expect(result.gradient[variable.to_s]).to be_within(1e-5).of(finite_difference(expression, data, variable))
    end
  end

  it 'supports common differentiable functions' do
    expression = 'sin(x) + cos(y) + sqrt(x) + exp(y) + log(x)'
    data = { x: 2.5, y: 0.7 }

    expect_gradient_matches_finite_difference(expression, data)
  end

  it 'supports bivariate functions' do
    expression = 'atan2(y, x) + hypot(y, x)'
    data = { x: 3.0, y: 4.0 }

    expect_gradient_matches_finite_difference(expression, data)
  end

  it 'supports the remaining arithmetic operators and array access' do
    result = calculator.evaluate_with_gradient!('x / y + x % y + z% + list[0]', x: 7, y: 3, z: 50, list: [2, 9])

    expect(result.result).to be_within(1e-9).of(7.0 / 3 + 1 + 0.5 + 2)
    expect(result.gradient.fetch('x')).to be_within(1e-9).of(1.0 / 3 + 1)
    expect(result.gradient.fetch('y')).to be_within(1e-9).of(-7.0 / 9 - 2)
    expect(result.gradient.fetch('z')).to be_within(1e-9).of(0.01)
  end

  it 'supports aggregates and CASE' do
    calculator.store_formula(:selected, "CASE rate WHEN 1 THEN x ELSE y END")
    result = calculator.evaluate_with_gradient!(
      'SUM(x, y) + AVG(2, 4) + x * y + MAX(x, 1) + MIN(y, 10) + selected',
      x: 2, y: 3, rate: 1
    )

    expect(result.gradient).to eq('x' => 6, 'y' => 4)
  end

  it 'reports ties and rounding boundaries' do
    tie = calculator.evaluate_with_gradient('MAX(x, y)', x: 1, y: 1)
    rounded = calculator.evaluate_with_gradient('ROUND(x)', x: 2.0)

    expect(tie.status).to eq(:non_differentiable)
    expect(rounded.status).to eq(:non_differentiable)
  end

  it 'reports invalid custom derivative shapes' do
    calculator.add_function(:bad, :numeric, ->(x) { x }, derivative: ->(x) { [x, x] })
    result = calculator.evaluate_with_gradient('bad(x)', x: 1)

    expect(result.status).to eq(:custom_function_error)
    expect(result.result).to eq(1)
  end

  it 'reports singular built-in points' do
    expect(calculator.evaluate_with_gradient('sqrt(x)', x: 0).status).to eq(:non_differentiable)
    expect(calculator.evaluate_with_gradient('x % y', x: 4, y: 2).status).to eq(:non_differentiable)
  end

  it 'supports exponent derivatives through both base and exponent' do
    expression = 'x ^ y'
    data = { x: 2.0, y: 3.0 }

    expect_gradient_matches_finite_difference(expression, data)
  end

  it 'supports custom derivative rules without perturbing inputs' do
    calls = 0
    calculator.add_function(
      :square,
      :numeric,
      ->(value) { calls += 1; value * value },
      derivative: ->(value) { 2 * value }
    )

    result = calculator.evaluate_with_gradient!('square(x) + square(x)', x: 4)

    expect(result.result).to eq(32)
    expect(result.gradient).to eq('x' => 16)
    expect(calls).to eq(2)
  end

  it 'accepts derivative rules through add_functions' do
    calculator.add_functions([
      [:cube, :numeric, ->(value) { value ** 3 }, nil, false, ->(value) { 3 * value ** 2 }]
    ])

    result = calculator.evaluate_with_gradient!('cube(x)', x: 2)

    expect(result.result).to eq(8)
    expect(result.gradient).to eq('x' => 12)
  end

  it 'reports unknown derivatives' do
    calculator.add_function(:mystery, :numeric, ->(value) { value * 3 })
    result = calculator.evaluate_with_gradient('mystery(x)', x: 2)

    expect(result.status).to eq(:unknown_derivative)
    expect(result.result).to eq(6)
    expect(result.gradient).to eq({})
  end

  it 'reports custom derivative failures explicitly' do
    calculator.add_function(
      :broken,
      :numeric,
      ->(value) { value + 1 },
      derivative: ->(_args) { raise 'derivative unavailable' }
    )
    result = calculator.evaluate_with_gradient('broken(x)', x: 2)

    expect(result.status).to eq(:custom_function_error)
    expect(result.result).to eq(3)
    expect(result.reasons.first.message).to include('derivative unavailable')
  end

  it 'reports custom implementation failures explicitly' do
    calculator.add_function(:failure, :numeric, ->(_value) { raise 'boom' })
    result = calculator.evaluate_with_gradient('failure(x)', x: 2)

    expect(result.status).to eq(:custom_function_error)
    expect(result.reasons.first.message).to include('boom')
  end

  it 'does not call side-effectful functions in the inactive IF branch' do
    calls = Hash.new(0)
    function_calls = Hash.new(0)
    calculator.add_function(
      :track,
      :numeric,
      ->(branch, value) { calls[branch] += 1; function_calls[branch] += 1; value },
      derivative: ->(args) { [0, 1] }
    )

    result = calculator.evaluate_with_gradient!(
      'IF(x > 0, track(1, x) * 2, track(2, x) * 3)',
      x: 4
    )

    expect(result.result).to eq(8)
    expect(result.gradient).to eq('x' => 2)
    expect(calls).to eq(1 => 1)
    expect(function_calls).to eq(1 => 1)
  end
end
