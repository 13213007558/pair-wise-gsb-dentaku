require 'spec_helper'
require 'dentaku'
require 'dentaku/calculator'

describe Dentaku::Calculator do
  let(:calculator) { described_class.new }

  describe '#evaluate_with_gradient!' do
    it 'returns the plain value and hand-computed partials for arithmetic with repeated variables' do
      # f = x*x + x*y - 3*x => df/dx = 2x + y - 3, df/dy = x
      result = calculator.evaluate_with_gradient!('x*x + x*y - 3*x', { x: 4, y: 2 }, wrt: %i[x y])

      expect(result.value).to eq(4 * 4 + 4 * 2 - 3 * 4)
      expect(result.gradient).to eq('x' => 2 * 4 + 2 - 3, 'y' => 4)
    end

    it 'matches the value that #evaluate! returns' do
      expression = '(a + b) * 2 - a / b'
      data = { a: 7, b: 3 }

      result = calculator.evaluate_with_gradient!(expression, data, wrt: %i[a b])
      expect(result.value).to eq(calculator.evaluate!(expression, data))
    end

    it 'differentiates powers with constant and variable exponents' do
      result = calculator.evaluate_with_gradient!('x ^ 3', { x: 2.0 }, wrt: %i[x])
      expect(result.value).to eq(8.0)
      expect(result.gradient['x']).to be_within(1e-12).of(12.0)

      result = calculator.evaluate_with_gradient!('x ^ y', { x: 2.0, y: 3.0 }, wrt: %i[x y])
      expect(result.gradient['x']).to be_within(1e-12).of(12.0)
      expect(result.gradient['y']).to be_within(1e-12).of(8.0 * Math.log(2))
    end

    it 'differentiates nested IF along the executed branch only' do
      expression = 'IF(x > 0, IF(y > 0, x * y, x - y), x + y)'

      result = calculator.evaluate_with_gradient!(expression, { x: 2, y: 3 }, wrt: %i[x y])
      expect(result.value).to eq(6)
      expect(result.gradient).to eq('x' => 3, 'y' => 2)

      result = calculator.evaluate_with_gradient!(expression, { x: 2, y: -3 }, wrt: %i[x y])
      expect(result.value).to eq(5)
      expect(result.gradient).to eq('x' => 1, 'y' => -1)

      result = calculator.evaluate_with_gradient!(expression, { x: -2, y: 3 }, wrt: %i[x y])
      expect(result.value).to eq(1)
      expect(result.gradient).to eq('x' => 1, 'y' => 1)
    end

    it 'differentiates through common math functions' do
      result = calculator.evaluate_with_gradient!('sin(x) + exp(x) * log(y)', { x: 0.5, y: 2.0 }, wrt: %i[x y])

      expect(result.gradient['x']).to be_within(1e-12).of(Math.cos(0.5) + Math.exp(0.5) * Math.log(2.0))
      expect(result.gradient['y']).to be_within(1e-12).of(Math.exp(0.5) / 2.0)
    end

    it 'differentiates sqrt, abs, min and max away from their kinks' do
      result = calculator.evaluate_with_gradient!('sqrt(x) + abs(y)', { x: 4.0, y: -3.0 }, wrt: %i[x y])
      expect(result.gradient['x']).to be_within(1e-12).of(0.25)
      expect(result.gradient['y']).to eq(-1)

      result = calculator.evaluate_with_gradient!('min(x, y) + max(x, y)', { x: 1, y: 2 }, wrt: %i[x y])
      expect(result.value).to eq(3)
      expect(result.gradient).to eq('x' => 1, 'y' => 1)
    end

    it 'treats min/max ties with identical gradients as differentiable' do
      result = calculator.evaluate_with_gradient!('min(x, x)', { x: 2 }, wrt: %i[x])
      expect(result.value).to eq(2)
      expect(result.gradient).to eq('x' => 1)
    end

    it 'reports zero gradient for requested variables the expression ignores' do
      result = calculator.evaluate_with_gradient!('x + 1', { x: 1 }, wrt: %i[x y])
      expect(result.gradient).to eq('x' => 1, 'y' => 0)
    end

    it 'handles an array of expressions like #evaluate! does' do
      results = calculator.evaluate_with_gradient!(['x + 1', 'x * 2'], { x: 3 }, wrt: %i[x])

      expect(results.map(&:value)).to eq([4, 6])
      expect(results.map(&:gradient)).to eq([{ 'x' => 1 }, { 'x' => 2 }])
    end

    it 'resolves stored formulas while differentiating' do
      calculator.store_formula('z', 'x * 2')
      result = calculator.evaluate_with_gradient!('z + 1', { x: 5 }, wrt: %i[x])

      expect(result.value).to eq(11)
      expect(result.gradient).to eq('x' => 2)
    end

    it 'matches central finite differences away from any boundary' do
      calculator.add_function(:discount, :numeric, ->(price, qty) { price * qty })
      calculator.register_derivative(:discount) { |values, _gradients| [values[1], values[0]] }

      expression = 'IF(qty > 10, discount(price, qty) * 0.9, discount(price, qty)) + sin(price) - qty ^ 2'
      data = { price: 12.34, qty: 56.78 }
      wrt = %w[price qty]
      result = calculator.evaluate_with_gradient!(expression, data, wrt: wrt)

      wrt.each do |variable|
        step = 1e-6
        raised = calculator.evaluate!(expression, data.merge(variable => data[variable.to_sym] + step))
        lowered = calculator.evaluate!(expression, data.merge(variable => data[variable.to_sym] - step))
        estimate = (raised - lowered) / (2.0 * step)

        expect(result.gradient[variable]).to be_within(1e-6).of(estimate)
      end
    end
  end

  describe 'branch execution' do
    it 'never calls functions on the untaken IF branch' do
      calls = []
      calculator.add_function(:taken, :numeric, ->(x) { calls << :taken; x })
      calculator.add_function(:skipped, :numeric, ->(x) { calls << :skipped; x })
      calculator.register_derivative(:taken) { [1] }
      calculator.register_derivative(:skipped) { [1] }

      result = calculator.evaluate_with_gradient!('IF(x > 0, taken(x), skipped(x))', { x: 1 }, wrt: %i[x])

      expect(result.value).to eq(1)
      expect(calls).to eq([:taken])
    end

    it 'ignores errors and unbound variables on the untaken branch' do
      expect {
        result = calculator.evaluate_with_gradient!('IF(x > 0, x * 2, 1 / 0)', { x: 1 }, wrt: %i[x])
        expect(result.value).to eq(2)
      }.not_to raise_error

      expect {
        calculator.evaluate_with_gradient!('IF(x > 0, x * 2, missing)', { x: 1 }, wrt: %i[x])
      }.not_to raise_error
    end

    it 'still raises errors from the taken branch' do
      expect {
        calculator.evaluate_with_gradient!('IF(x > 0, 1 / 0, x)', { x: 1 }, wrt: %i[x])
      }.to raise_error(Dentaku::ZeroDivisionError)
    end
  end

  describe 'custom function derivatives' do
    it 'chains a separately registered derivative rule' do
      calculator.add_function(:area, :numeric, ->(width, height) { width * height })
      calculator.register_derivative(:area) { |values, _gradients| [values[1], values[0]] }

      result = calculator.evaluate_with_gradient!('area(w, h) + h', { w: 3, h: 4 }, wrt: %i[w h])

      expect(result.value).to eq(16)
      expect(result.gradient).to eq('w' => 4, 'h' => 3 + 1)
    end

    it 'accepts a derivative rule at registration time' do
      calculator.add_function(:double, :numeric, ->(x) { x * 2 }, derivative: ->(_values, _gradients) { [2] })

      result = calculator.evaluate_with_gradient!('double(x)', { x: 21 }, wrt: %i[x])

      expect(result.value).to eq(42)
      expect(result.gradient).to eq('x' => 2)
    end

    it 'raises UnsupportedDerivativeError for unregistered functions instead of approximating' do
      calculator.add_function(:mystery, :numeric, ->(x) { x * 2 })

      expect {
        calculator.evaluate_with_gradient!('mystery(x)', { x: 1 }, wrt: %i[x])
      }.to raise_error(Dentaku::UnsupportedDerivativeError, /mystery/)
    end

    it 'does not call the unregistered function more than normal evaluation would' do
      calls = 0
      calculator.add_function(:counted, :numeric, ->(x) { calls += 1; x })

      expect {
        calculator.evaluate_with_gradient!('counted(x)', { x: 1 }, wrt: %i[x])
      }.to raise_error(Dentaku::UnsupportedDerivativeError)
      expect(calls).to eq(0)
    end
  end

  describe 'non-differentiable points' do
    it 'reports comparison boundaries' do
      expect {
        calculator.evaluate_with_gradient!('IF(x >= 5, 1, 2)', { x: 5 }, wrt: %i[x])
      }.to raise_error(Dentaku::NonDifferentiableError) { |error|
        expect(error.reason).to eq(:comparison_boundary)
      }
    end

    it 'reports ABS at zero' do
      expect {
        calculator.evaluate_with_gradient!('abs(x)', { x: 0 }, wrt: %i[x])
      }.to raise_error(Dentaku::NonDifferentiableError) { |error|
        expect(error.reason).to eq(:abs_zero)
      }
    end

    it 'reports MIN/MAX ties between independent variables' do
      expect {
        calculator.evaluate_with_gradient!('min(x, y)', { x: 1, y: 1 }, wrt: %i[x y])
      }.to raise_error(Dentaku::NonDifferentiableError) { |error|
        expect(error.reason).to eq(:min_max_tie)
      }

      expect {
        calculator.evaluate_with_gradient!('max(x, y)', { x: 2, y: 2 }, wrt: %i[x y])
      }.to raise_error(Dentaku::NonDifferentiableError) { |error|
        expect(error.reason).to eq(:min_max_tie)
      }
    end

    it 'does not report boundaries the evaluation never reaches' do
      result = calculator.evaluate_with_gradient!('IF(x > 0, 1, abs(y))', { x: 1, y: 0 }, wrt: %i[x y])
      expect(result.value).to eq(1)
      expect(result.gradient).to eq('x' => 0, 'y' => 0)
    end
  end

  describe '#evaluate_with_gradient' do
    it 'returns nil instead of raising, like #evaluate' do
      calculator.add_function(:mystery, :numeric, ->(x) { x })

      expect(calculator.evaluate_with_gradient('mystery(x)', { x: 1 }, wrt: %i[x])).to be_nil
      expect(calculator.evaluate_with_gradient('1 / 0', {}, wrt: [])).to be_nil
      expect(calculator.evaluate_with_gradient('unknown + 1', {}, wrt: [])).to be_nil
    end

    it 'yields the expression and error to a block, like #evaluate' do
      yielded = nil
      calculator.evaluate_with_gradient('1 / 0', {}, wrt: []) { |expression, error| yielded = [expression, error] }

      expect(yielded[0]).to eq('1 / 0')
      expect(yielded[1]).to be_an_instance_of(Dentaku::ZeroDivisionError)
    end
  end

  describe 'plain evaluation' do
    it 'is unaffected by derivative registration' do
      calculator.add_function(:area, :numeric, ->(w, h) { w * h }, derivative: ->(*_) { [0, 0] })

      expect(calculator.evaluate('area(3, 4) + 1')).to eq(13)
      expect(calculator.evaluate!('IF(1 > 0, abs(-2), min(1, 1))')).to eq(2)
    end
  end
end
