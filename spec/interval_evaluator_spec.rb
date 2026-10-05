require 'dentaku'
require 'spec_helper'

RSpec.describe 'interval evaluation' do
  let(:calculator) { Dentaku::Calculator.new }

  def evaluate(expression, data = {}, precision: nil)
    calculator.evaluate_interval!(expression, data, precision: precision)
  end

  # Assert that every value produced by sampling the input grids is inside
  # the reported enclosure.
  def expect_enclosure(expression, grids, skipped: nil)
    interval_inputs = grids.transform_values { |values| Dentaku::Interval[values.first, values.last] }
    result = evaluate(expression, interval_inputs)
    names = grids.keys
    combinations = grids.values[0]&.product(*grids.values[1..]) || [[]]
    combinations.each do |point|
      data = names.zip(point).to_h
      scalar = begin
        calculator.store(data) { calculator.evaluate!(expression) }
      rescue Dentaku::ZeroDivisionError, ::ZeroDivisionError
        next
      end

      next if skipped&.call(data)

      expect(result.interval.cover?(scalar)).to be(true),
        "expected #{expression}=#{scalar} at #{data} to be inside #{result.interval}"
    end
    result
  end

  describe 'the endpoint method is insufficient' do
    it 'misses the interior maximum of x*(1-x)' do
      result = evaluate('x * (1 - x)', { x: Dentaku::Interval[0, 1] })
      expect(result.interval.to_a).to eq [0, 1]

      endpoint_values = [0, 1].map { |x| calculator.evaluate!('x * (1 - x)', { x: x }) }
      expect(endpoint_values).to eq [0, 0]
      interior = calculator.evaluate!('x * (1 - x)', { x: Rational(1, 2) })
      expect(interior).to eq Rational(1, 4)
      expect(Dentaku::Interval[endpoint_values.min, endpoint_values.max].cover?(interior)).to be false
      expect(result.interval.cover?(interior)).to be true
    end
  end

  describe 'four arithmetic operations' do
    it 'encloses price times discount for price [10,12] and discount [0.9,0.95]' do
      result = evaluate(
        'price * discount',
        { price: Dentaku::Interval[10, 12],
          discount: Dentaku::Interval[Rational(9, 10), Rational(95, 100)] }
      )
      expect(result.interval.low).to eq 9
      expect(result.interval.high).to eq Rational(57, 5)
    end

    it 'contains every sampled value of a shared variable' do
      values = (0..8).map { |index| Rational(index, 8) }
      result = expect_enclosure('x * (1 - x)', { x: values })
      expect(result.notes.map(&:code)).to eq []
    end

    it 'encloses addition, subtraction and division on grids' do
      left = (-3..3).map { |index| Rational(index, 2) }
      right = (-2..4).map { |index| Rational(index, 2) }
      %w[a+b a-b a*b].each do |expression|
        expect_enclosure(expression, { a: left, b: right })
      end
      divisor = (1..6).map { |index| Rational(index, 2) }
      expect_enclosure('a / b', { a: left, b: divisor })
    end
  end

  describe 'division across zero' do
    it 'returns an unbounded image and records the undefined divisor point' do
      result = evaluate('1 / x', { x: Dentaku::Interval[-1, 2] })
      expect(result.unbounded?).to be true
      expect(result.undefined_points).to eq [0]
      expect(result.notes.map(&:code)).to include :unbounded_result
    end

    it 'raises when the divisor is the single point zero' do
      expect { evaluate('1 / x', { x: Dentaku::Interval.point(0) }) }
        .to raise_error(Dentaku::ZeroDivisionError)
    end
  end

  describe 'integer powers' do
    it 'encloses even and odd powers on grids' do
      values = (-4..4).map { |index| Rational(index, 2) }
      expect_enclosure('x ^ 2', { x: values })
      expect_enclosure('x ^ 3', { x: values })
    end

    it 'encloses interval exponents within the enumeration limit' do
      result = evaluate('2 ^ n', { n: Dentaku::Interval[0, 4] })
      expect(result.interval.to_a).to eq [1, 16]
    end

    it 'flags non-integer exponent intervals as unsupported' do
      result = evaluate('x ^ y', {
        x: Dentaku::Interval[1, 2],
        y: Dentaku::Interval[1, Rational(3, 2)]
      })
      expect(result.notes.map(&:code)).to include :unsupported_operation
      expect(result.interval).to eq Dentaku::Interval::UNIVERSE
    end
  end

  describe 'min, max and abs' do
    it 'bounds min and max without assuming independence' do
      result = evaluate('min(x, 0) + max(x, 0)', { x: Dentaku::Interval[-3, 2] })
      expect(result.interval.to_a).to eq [-3, 2]
    end

    it 'encloses abs on a grid' do
      values = (-5..5).map { |index| Rational(index, 2) }
      expect_enclosure('abs(x)', { x: values })
    end
  end

  describe 'comparison-driven IF' do
    it 'takes the true branch when the predicate is provably true' do
      result = evaluate('IF(x > 0, 1, -1)', { x: Dentaku::Interval[2, 4] })
      expect(result.interval).to eq Dentaku::Interval.point(1)
      expect(result.notes).to eq []
    end

    it 'takes the false branch when the predicate is provably false' do
      result = evaluate('IF(x > 0, 1, -1)', { x: Dentaku::Interval[-4, -2] })
      expect(result.interval).to eq Dentaku::Interval.point(-1)
      expect(result.notes).to eq []
    end

    it 'merges feasible branches when the comparison is undecidable' do
      result = evaluate('IF(x > 0, x, -x)', { x: Dentaku::Interval[-2, 3] })
      expect(result.interval.to_a).to eq [-3, 3]
      expect(result.notes.map(&:code)).to eq [:indeterminate_branch]
    end

    it 'still encloses every sample when a branch is merged' do
      values = (-4..4).map { |index| Rational(index, 2) }
      result = expect_enclosure('IF(x > 0, x * 2, -x)', { x: values })
      expect(result.notes.map(&:code)).to include :indeterminate_branch
    end

    it 'supports and/or/not predicates with tri-state logic' do
      undecided = evaluate('IF(x > 0 and y < 0, 1, 0)',
                           { x: Dentaku::Interval[-1, 2], y: Dentaku::Interval[-1, 2] })
      expect(undecided.notes.map(&:code)).to include :indeterminate_branch

      decided = evaluate('IF(x > 0 or y < 0, 1, 0)',
                         { x: Dentaku::Interval[1, 2], y: Dentaku::Interval[-1, 2] })
      expect(decided.interval).to eq Dentaku::Interval.point(1)
      expect(decided.notes.map(&:code)).to eq []
    end
  end

  describe 'custom functions' do
    it 'participates in interval mode only with a registered interval rule' do
      calculator.add_function(:plain, :numeric, ->(value) { value * 2 })
      plain = evaluate('plain(x)', { x: Dentaku::Interval[1, 3] })
      expect(plain.interval).to eq Dentaku::Interval::UNIVERSE
      expect(plain.notes.map(&:code)).to eq [:unknown_function_rule]

      calculator.add_interval_function(:doubled) { |value| Dentaku::Interval.new(value.low * 2, value.high * 2) }
      ruled = evaluate('doubled(x)', { x: Dentaku::Interval[1, 3] })
      expect(ruled.interval.to_a).to eq [2, 6]
      expect(ruled.notes.map(&:code)).to eq []
    end

    it 'also evaluates a pointwise call through the registered interval rule' do
      calculator.add_interval_function(:tripled) { |value| Dentaku::Interval.new(value.low * 3, value.high * 3) }
      expect(calculator.evaluate!('tripled(x)', { x: 2 })).to eq 6
    end
  end

  describe 'error direction and reporting' do
    it 'rounds outward by default and records it' do
      result = evaluate('x / 3', { x: Dentaku::Interval[1, 2] }, precision: 3)
      expect(result.interval.low.to_f).to be <= Rational(1, 3).to_f
      expect(result.interval.high.to_f).to be >= Rational(2, 3).to_f
      expect(result.notes.map(&:code)).to include :outward_rounding
    end

    it 'keeps exact Rational endpoints when precision is nil' do
      result = evaluate('x / 3', { x: Dentaku::Interval[1, 2] }, precision: nil)
      expect(result.interval.to_a).to eq [Rational(1, 3), Rational(2, 3)]
      expect(result.notes.map(&:code)).to eq []
    end
  end

  describe 'input forms and failures' do
    it 'accepts two-element arrays as interval inputs' do
      result = evaluate('x + 1', { x: [10, 12] })
      expect(result.interval.to_a).to eq [11, 13]
    end

    it 'raises for unbound variables' do
      expect { evaluate('x + 1', {}) }.to raise_error(Dentaku::UnboundVariableError)
    end

    it 'returns nil from the non-bang method on failure' do
      expect(calculator.evaluate_interval('1 / x', { x: Dentaku::Interval.point(0) })).to be_nil
    end
  end
end
