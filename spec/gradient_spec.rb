require 'spec_helper'
require 'dentaku'

describe Dentaku::Calculator do
  let(:calculator) { described_class.new }

  describe '#evaluate_with_gradient!' do
    it 'returns the normal result and first derivatives for repeated variables' do
      result = calculator.evaluate_with_gradient!(
        'x*x + y/x',
        { x: 3.0, y: 4.0 },
        [:x, :y]
      )

      expect(result.value).to eq(calculator.evaluate!('x*x + y/x', x: 3.0, y: 4.0))
      expect(result[:result]).to eq(result.value)
      expect(result.gradient.fetch('x')).to be_within(1e-12).of(50.0 / 9)
      expect(result.gradient.fetch('y')).to be_within(1e-12).of(1.0 / 3)
    end

    it 'supports arithmetic, power and common math functions' do
      formula = '(x + y) * x - y / x + x^2 + sqrt(x) + sin(y) + log(x)'
      data = { x: 2.5, y: 0.7 }
      result = calculator.evaluate_with_gradient!(formula, data, [:x, :y])

      epsilon = 1e-7
      expected_x = finite_difference(formula, data, :x, epsilon)
      expected_y = finite_difference(formula, data, :y, epsilon)

      expect(result.value).to eq(calculator.evaluate!(formula, data))
      expect(result.gradient.fetch('x')).to be_within(1e-6).of(expected_x)
      expect(result.gradient.fetch('y')).to be_within(1e-6).of(expected_y)
    end

    it 'supports modulo away from its integer-remainder boundaries' do
      result = calculator.evaluate_with_gradient!(
        'x % y',
        { x: 7.0, y: 3.0 },
        [:x, :y]
      )

      expect(result.value).to eq(1)
      expect(result.gradient).to eq('x' => 1, 'y' => -2)
    end

    it 'matches hand derivatives through nested IF and a registered custom function' do
      calculator.add_function(:cube, :numeric, ->(x) { x**3 })
      calculator.add_derivative(:cube, ->(x) { 3 * x**2 })
      calculator.add_function(:bad, :numeric, ->(x) { raise 'bad branch' })
      calculator.add_function(:unused, :numeric, ->(x) { x })

      formula = 'if(x < 2, if(y > 0, cube(x), bad(x)), unused(y))'
      result = calculator.evaluate_with_gradient!(
        formula,
        { x: 1.5, y: 2.0 },
        [:x, :y]
      )

      expect(result.value).to eq(3.375)
      expect(result.gradient).to eq('x' => 6.75, 'y' => 0.0)
    end

    it 'evaluates only the selected IF branch' do
      calls = Hash.new(0)
      calculator.add_function(:explode, :numeric, ->(x) {
        calls[:explode] += 1
        raise 'this branch must not run'
      })
      calculator.add_function(:unused, :numeric, ->(x) {
        calls[:unused] += 1
        x
      })
      calculator.add_function(:ok, :numeric, ->(x) {
        calls[:ok] += 1
        x * 2
      })
      calculator.add_derivative(:ok, ->(_x) { 2 })

      result = calculator.evaluate_with_gradient!(
        'if(x > 0, ok(x), explode(unused(z)))',
        { x: 3 },
        [:x]
      )

      expect(result.value).to eq(6)
      expect(result.gradient).to eq('x' => 2.0)
      expect(calls.fetch(:ok)).to eq(1)
      expect(calls.fetch(:explode, 0)).to eq(0)
      expect(calls.fetch(:unused, 0)).to eq(0)
    end

    it 'does not require variables used only by an unselected branch' do
      calculator.add_function(:explode, :numeric, -> { raise 'boom' })

      result = calculator.evaluate_with_gradient!(
        'if(x > 0, 2 * x, explode() + z)',
        { x: 2 },
        [:x]
      )

      expect(result.value).to eq(4)
      expect(result.gradient).to eq('x' => 2.0)
    end

    it 'accepts a derivative when registering a custom function' do
      calculator.add_function(
        :double,
        :numeric,
        ->(x) { 2 * x },
        nil,
        derivative: ->(_x) { 2 }
      )

      result = calculator.evaluate_with_gradient!('double(x)', { x: 4 }, [:x])
      expect(result.value).to eq(8)
      expect(result.gradient).to eq('x' => 2.0)
    end

    it 'supports multivariate custom derivative rules' do
      calculator.add_function(:plane, :numeric, ->(x, y) { 3 * x - 2 * y })
      calculator.add_derivative(:plane, ->(_x, _y) { [3, -2] })

      result = calculator.evaluate_with_gradient!(
        'plane(x, y) + x',
        { x: 1, y: 1 },
        [:x, :y]
      )

      expect(result.gradient).to eq('x' => 4.0, 'y' => -2.0)
    end

    it 'supports custom rules over array arguments' do
      calculator.add_function(:total, :numeric, ->(values) { values.sum })
      calculator.add_derivative(:total, ->(values) { values.map { 1 } })

      result = calculator.evaluate_with_gradient!(
        'total({x, y}) + z',
        { x: 1.0, y: 2.0, z: 3.0 },
        [:x, :y, :z]
      )

      expect(result.value).to eq(6.0)
      expect(result.gradient).to eq('x' => 1, 'y' => 1, 'z' => 1)
    end

    it 'differentiates built-in aggregate arguments supplied as arrays' do
      result = calculator.evaluate_with_gradient!(
        'sum({x, y}, z)',
        { x: 1.0, y: 2.0, z: 3.0 },
        [:x, :y, :z]
      )

      expect(result.value).to eq(6.0)
      expect(result.gradient).to eq('x' => 1, 'y' => 1, 'z' => 1)
    end

    it 'allows custom logical functions without derivative rules' do
      calculator.add_function(:active, :logical, ->(_value) { true })

      result = calculator.evaluate_with_gradient!(
        'if(active(x), x + 1, 0)',
        { x: 2 },
        [:x]
      )

      expect(result.value).to eq(3)
      expect(result.gradient).to eq('x' => 1)
    end

    it 'executes an unregistered numeric custom function once before rejecting differentiation' do
      calls = 0
      calculator.add_function(:mystery, :numeric, ->(x) {
        calls += 1
        x + 1
      })

      expect do
        calculator.evaluate_with_gradient!('mystery(x)', { x: 1 }, [:x])
      end.to raise_error(
        Dentaku::DifferentiationError,
        'No derivative rule is registered for function MYSTERY'
      )
      expect(calls).to eq(1)
    end

    it 'does not invoke an unsupported function in an unselected IF branch' do
      calls = 0
      calculator.add_function(:mystery, :numeric, ->(x) {
        calls += 1
        x
      })

      result = calculator.evaluate_with_gradient!(
        'if(x > 0, 1, mystery(x))',
        { x: 1 },
        [:x]
      )

      expect(result.value).to eq(1)
      expect(calls).to eq(0)
    end

    it 'reports IF comparator boundaries as non-differentiable' do
      ['x == 1', 'x < 1', 'x <= 1', 'x > 1', 'x >= 1'].each do |predicate|
        formula = "if(#{predicate}, x, -x)"

        expect do
          calculator.evaluate_with_gradient!(formula, { x: 1 }, [:x])
        end.to raise_error(Dentaku::DifferentiationError, /not differentiable/)
      end
    end

    it 'reports abs zero and min/max ties as non-differentiable' do
      expect do
        calculator.evaluate_with_gradient!('abs(x)', { x: 0 }, [:x])
      end.to raise_error(Dentaku::DifferentiationError, /ABS.*not differentiable/)

      expect do
        calculator.evaluate_with_gradient!('min(x, 1)', { x: 1 }, [:x])
      end.to raise_error(Dentaku::DifferentiationError, /MIN.*not differentiable/)

      expect do
        calculator.evaluate_with_gradient!('max(x, 1)', { x: 1 }, [:x])
      end.to raise_error(Dentaku::DifferentiationError, /MAX.*not differentiable/)

      expect do
        calculator.evaluate_with_gradient!('max(x, x)', { x: 1 }, [:x])
      end.to raise_error(Dentaku::DifferentiationError, /not differentiable/)

      expect do
        calculator.evaluate_with_gradient!('x % y', { x: 6.0, y: 3.0 }, [:x, :y])
      end.to raise_error(Dentaku::DifferentiationError, /not differentiable/)
    end

    it 'reports non-smooth math function boundaries' do
      expect do
        calculator.evaluate_with_gradient!('sqrt(x)', { x: 0 }, [:x])
      end.to raise_error(Dentaku::DifferentiationError, /SQRT.*not differentiable/)

      expect do
        calculator.evaluate_with_gradient!('acos(x)', { x: 1 }, [:x])
      end.to raise_error(Dentaku::DifferentiationError, /ACOS.*not differentiable/)
    end

    it 'accepts variables as a keyword argument' do
      result = calculator.evaluate_with_gradient!('x + 2', { x: 1 }, variables: [:x])
      expect(result.gradient).to eq('x' => 1)
    end

    it 'returns gradients for requested variables that are unused by the selected branch' do
      result = calculator.evaluate_with_gradient!(
        'if(x > 0, x, y)',
        { x: 1, y: 2 },
        [:x, :y]
      )

      expect(result.gradient).to eq('x' => 1, 'y' => 0)
    end
  end

  describe '#evaluate_with_gradient' do
    it 'keeps the non-bang nil-on-error convention' do
      calculator.add_function(:mystery, :numeric, ->(x) { x })

      result = calculator.evaluate_with_gradient('mystery(x)', { x: 1 }, [:x])
      expect(result).to be_nil
    end

    it 'passes Dentaku errors to the optional block' do
      calculator.add_function(:mystery, :numeric, ->(x) { x })
      captured = nil

      calculator.evaluate_with_gradient('mystery(x)', { x: 1 }, [:x]) do |_expression, error|
        captured = error
      end

      expect(captured).to be_a(Dentaku::DifferentiationError)
    end
  end

  describe 'ordinary evaluation compatibility' do
    it 'preserves evaluate return and evaluate! exceptions' do
      expect(calculator.evaluate('1 / 0')).to be_nil
      expect do
        calculator.evaluate!('1 / 0')
      end.to raise_error(Dentaku::ZeroDivisionError)
    end

    it 'preserves ordinary function result values' do
      calculator.add_function(:cube, :numeric, ->(x) { x**3 })
      calculator.add_derivative(:cube, ->(x) { 3 * x**2 })

      expect(calculator.evaluate!('cube(3)')).to eq(27)
    end
  end

  def finite_difference(formula, data, variable, epsilon)
    plus = data.merge(variable => data.fetch(variable) + epsilon)
    minus = data.merge(variable => data.fetch(variable) - epsilon)
    (calculator.evaluate!(formula, plus).to_f - calculator.evaluate!(formula, minus).to_f) /
      (2 * epsilon)
  end
end
