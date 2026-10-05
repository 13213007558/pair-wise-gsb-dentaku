require 'spec_helper'
require 'dentaku'

describe Dentaku::Interval do
  def interval(lo, hi)
    described_class.new(lo, hi)
  end

  describe '.from' do
    it 'passes intervals through and coerces scalars, ranges, and pairs' do
      original = interval(1, 2)
      expect(described_class.from(original)).to equal(original)
      expect(described_class.from(3)).to eq(described_class.point(3))
      expect(described_class.from(1..2)).to eq(interval(1, 2))
      expect(described_class.from([1, 2])).to eq(interval(1, 2))
      expect(described_class.from(..2)).to eq(interval(-Float::INFINITY, 2))
      expect(described_class.from(1..)).to eq(interval(1, Float::INFINITY))
    end

    it 'rejects values it cannot coerce' do
      expect { described_class.from('nope') }.to raise_error(ArgumentError)
      expect { described_class.from([1, 2, 3]) }.to raise_error(ArgumentError)
    end
  end

  it 'rejects a lower bound above the upper bound' do
    expect { interval(2, 1) }.to raise_error(ArgumentError)
  end

  describe 'rounding direction' do
    it 'widens bounds outward by one ulp' do
      expect(described_class.widen_lo(1.0)).to eq(1.0.prev_float)
      expect(described_class.widen_hi(1.0)).to eq(1.0.next_float)
      expect(described_class.widen_lo(-Float::INFINITY)).to eq(-Float::INFINITY)
      expect(described_class.widen_hi(Float::INFINITY)).to eq(Float::INFINITY)
    end

    it 'rounds lower bounds down and upper bounds up, never inward' do
      third = described_class.point(1) / described_class.point(3)
      expect(third.lo).to be < 1.0 / 3.0
      expect(third.hi).to be > 1.0 / 3.0

      sum = interval(0.1, 0.2) + interval(0.3, 0.4)
      expect(sum.lo).to be <= 0.4
      expect(sum.hi).to be >= 0.6
    end
  end

  describe 'arithmetic' do
    it 'adds and subtracts endpoint-wise' do
      expect((interval(1, 2) + interval(3, 4)).lo).to eq(4.0.prev_float)
      expect((interval(1, 2) + interval(3, 4)).hi).to eq(6.0.next_float)
      expect((interval(1, 2) - interval(3, 4)).hi).to eq((-1.0).next_float)
    end

    it 'multiplies with mixed signs' do
      product = interval(-1, 2) * interval(3, 4)
      expect(product.lo).to be <= -4
      expect(product.hi).to be >= 8
    end

    it 'divides when the divisor excludes zero' do
      quotient = interval(1, 2) / interval(0.5, 1)
      expect(quotient.lo).to be <= 1
      expect(quotient.hi).to be >= 4
    end

    it 'is unbounded when the divisor spans zero' do
      expect(interval(1, 2) / interval(-1, 2)).to be_unbounded
    end

    it 'is one-sided unbounded when the divisor only touches zero' do
      quotient = interval(1, 2) / interval(0, 2)
      expect(quotient.lo).to be <= 0.5
      expect(quotient.hi).to eq(Float::INFINITY)
    end

    it 'is empty when the divisor is exactly zero' do
      expect(interval(1, 2) / interval(0, 0)).to be_empty
    end
  end

  describe 'integer powers' do
    it 'handles even powers over a zero-spanning base' do
      result = interval(-1, 2)**2
      expect(result.lo).to eq(0.0)
      expect(result.hi).to be >= 4
    end

    it 'handles odd powers monotonically' do
      result = interval(-1, 2)**3
      expect(result.lo).to be <= -1
      expect(result.hi).to be >= 8
    end

    it 'handles negative powers like division' do
      expect((interval(1, 2)**-1).lo).to be <= 0.5
      expect((interval(1, 2)**-1).hi).to be >= 1
      expect(interval(-1, 1)**-1).to be_unbounded
      expect(interval(0, 0)**-1).to be_empty
    end

    it 'treats a zero exponent as one' do
      expect(interval(0, 5)**0).to eq(described_class.point(1))
    end
  end

  describe 'min, max, abs, hull' do
    it 'computes elementwise bounds' do
      expect(interval(1, 5).min(interval(2, 3))).to eq(interval(1, 3))
      expect(interval(1, 5).max(interval(2, 3))).to eq(interval(2, 5))
      expect(interval(-3, 1).abs).to eq(interval(0, 3))
      expect(interval(1, 3).abs).to eq(interval(1, 3))
      expect(interval(1, 2).hull(interval(5, 6))).to eq(interval(1, 6))
    end
  end

  describe 'tri-state comparisons' do
    it 'resolves to :true, :false, or :indeterminate' do
      expect(interval(1, 3).lt(interval(5, 6))).to eq(:true)
      expect(interval(1, 3).gt(interval(5, 6))).to eq(:false)
      expect(interval(1, 6).lt(interval(5, 7))).to eq(:indeterminate)
      expect(interval(2, 2).eq(interval(2, 2))).to eq(:true)
      expect(interval(1, 2).eq(interval(3, 4))).to eq(:false)
      expect(interval(1, 3).eq(interval(2, 4))).to eq(:indeterminate)
      expect(interval(1, 2).ne(interval(3, 4))).to eq(:true)
    end
  end
end

describe 'interval evaluation' do
  let(:calculator) { Dentaku::Calculator.new }

  def evaluate_interval(expression, data = {})
    calculator.evaluate_interval(expression, data)
  end

  describe 'the four arithmetic operations' do
    it 'evaluates a ranged price and discount without endpoint-only sampling' do
      result = evaluate_interval('price * (1 - discount)', price: [10, 12], discount: [0.1, 0.2])
      expect(result.interval.lo).to be <= 8.0
      expect(result.interval.hi).to be >= 10.8
      expect(result.relaxations).to be_empty
    end

    it 'supports addition, subtraction, and division' do
      expect(evaluate_interval('a + b', a: [1, 2], b: [3, 4]).interval.lo).to be <= 4
      expect(evaluate_interval('a - b', a: [1, 2], b: [3, 4]).interval.hi).to be >= -1
      quotient = evaluate_interval('a / b', a: [1, 2], b: [0.5, 1]).interval
      expect(quotient.lo).to be <= 1
      expect(quotient.hi).to be >= 4
    end

    it 'accepts scalars, ranges, and Dentaku::Interval inputs' do
      expect(evaluate_interval('x * 2', x: 3).interval.contains?(6)).to be(true)
      expect(evaluate_interval('x * 2', x: 1..2).interval.hi).to be >= 4
      expect(evaluate_interval('x * 2', x: Dentaku::Interval.new(1, 2)).interval.hi).to be >= 4
    end

    it 'raises for unbound variables' do
      expect { evaluate_interval('x + 1') }.to raise_error(Dentaku::UnboundVariableError)
    end
  end

  describe 'integer powers' do
    it 'covers even and odd exponents' do
      square = evaluate_interval('x ^ 2', x: [-1, 2]).interval
      expect(square.lo).to eq(0.0)
      expect(square.hi).to be >= 4
      cube = evaluate_interval('x ^ 3', x: [-1, 2]).interval
      expect(cube.lo).to be <= -1
      expect(cube.hi).to be >= 8
    end

    it 'treats a negative exponent over a zero-spanning base as unbounded and undefined' do
      result = evaluate_interval('x ^ -1', x: [-1, 1])
      expect(result).to be_unbounded
      expect(result.undefined).to eq([Dentaku::Interval.point(0)])
      expect(result.relaxations.map(&:kind)).to include(:division_by_zero)
    end

    it 'supports non-integer exponents on non-negative bases' do
      result = evaluate_interval('x ^ 0.5', x: [0, 4])
      expect(result.include?(2.0)).to be(true)
    end
  end

  describe 'min, max, and abs' do
    it 'evaluates the built-in functions over intervals' do
      expect(evaluate_interval('MIN(a, b)', a: [1, 5], b: [2, 3]).interval).to eq(Dentaku::Interval.new(1, 3))
      expect(evaluate_interval('MAX(a, b)', a: [1, 5], b: [2, 3]).interval).to eq(Dentaku::Interval.new(2, 5))
      expect(evaluate_interval('ABS(x)', x: [-3, 1]).interval).to eq(Dentaku::Interval.new(0, 3))
    end
  end

  describe 'comparisons' do
    it 'returns a tri-state value' do
      expect(evaluate_interval('x < 5', x: [1, 3]).logical).to eq(:true)
      expect(evaluate_interval('x < 5', x: [6, 7]).logical).to eq(:false)
      expect(evaluate_interval('x < 5', x: [1, 6]).logical).to eq(:indeterminate)
    end
  end

  describe 'comparison-driven IF' do
    it 'picks the only feasible branch when the comparison is decided' do
      result = evaluate_interval('IF(x > 0, 1 / x, 99)', x: [1, 2])
      expect(result.interval.lo).to be <= 0.5
      expect(result.interval.hi).to be >= 1
      expect(result.relaxations).to be_empty
      expect(result.undefined).to be_empty
    end

    it 'merges both branches and marks the relaxation when the comparison is indeterminate' do
      result = evaluate_interval('IF(x >= 10, price, 0)', x: [5, 15], price: [10, 12])
      expect(result.interval.lo).to be <= 0
      expect(result.interval.hi).to be >= 12
      expect(result.relaxations.map(&:kind)).to include(:branch_merge)
    end

    it 'evaluates logical combinators in conditions' do
      result = evaluate_interval('IF(AND(x > 0, x < 10), 1, 0)', x: [-1, 5])
      expect(result.interval).to eq(Dentaku::Interval.new(0, 1))
      expect(result.relaxations.map(&:kind)).to include(:branch_merge)
    end
  end

  describe 'division with a zero-spanning divisor' do
    it 'distinguishes unbounded results from undefined points' do
      result = evaluate_interval('1 / x', x: [-1, 2])
      expect(result).to be_unbounded
      expect(result.undefined).to eq([Dentaku::Interval.point(0)])
      expect(result.relaxations.map(&:kind)).to include(:division_by_zero)
    end

    it 'is one-sided unbounded when the divisor only touches zero' do
      result = evaluate_interval('1 / x', x: [0, 2])
      expect(result.interval.lo).to be <= 0.5
      expect(result.interval.hi).to eq(Float::INFINITY)
      expect(result.undefined).to eq([Dentaku::Interval.point(0)])
    end

    it 'is empty when the divisor is exactly zero' do
      result = evaluate_interval('1 / x', x: [0, 0])
      expect(result.interval).to be_empty
      expect(result).to be_undefined
    end
  end

  describe 'custom functions' do
    it 'widens and marks functions without an interval rule' do
      calculator.add_function(:double, :numeric, ->(x) { x * 2 })
      result = evaluate_interval('double(x)', x: [1, 2])
      expect(result).to be_unbounded
      expect(result.relaxations.map(&:kind)).to include(:unknown_rule)
      expect(result.relaxations.map(&:message).join).to include('double')
    end

    it 'widens and marks built-in functions without an interval rule' do
      result = evaluate_interval('ROUND(x, 1)', x: [1, 2])
      expect(result).to be_unbounded
      expect(result.relaxations.map(&:kind)).to include(:unknown_rule)
    end

    it 'evaluates custom functions that provide an interval rule' do
      calculator.add_function(:double, :numeric, ->(x) { x * 2 })
      calculator.add_interval_rule(:double) { |x| x * 2 }
      result = evaluate_interval('double(x)', x: [1, 2])
      expect(result.interval.lo).to be <= 2
      expect(result.interval.hi).to be >= 4
      expect(result.relaxations).to be_empty
    end
  end

  describe 'shared variables' do
    it 'resolves variables stored on the calculator, including formulas' do
      calculator.store(price: Dentaku::Interval.new(10, 12))
      calculator.store(tax: 'price * 0.1')
      result = calculator.evaluate_interval('price + tax')
      expect(result.interval.lo).to be <= 11.0
      expect(result.interval.hi).to be >= 13.2
      (10..12).each do |price|
        expect(result.include?(price * 1.1)).to be(true)
      end
    end
  end

  describe 'x * (1 - x)' do
    it 'shows why evaluating only the endpoints is not enough' do
      result = evaluate_interval('x * (1 - x)', x: Dentaku::Interval.new(0, 1))

      endpoints = [0.0, 1.0].map { |v| calculator.evaluate('x * (1 - x)', x: v) }
      endpoint_range = (endpoints.min..endpoints.max)
      expect(endpoint_range).not_to cover(0.25)

      expect(result.include?(0.25)).to be(true)

      (0..100).each do |i|
        v = i / 100.0
        expect(result.include?(v * (1 - v))).to be(true)
      end
    end
  end

  describe 'containment over enumerable small intervals' do
    it 'contains every sample of the input grid' do
      result = evaluate_interval('price * (1 - discount)', price: [10, 12], discount: [0.1, 0.2])

      (10..12).each do |price|
        [0.1, 0.125, 0.15, 0.175, 0.2].each do |discount|
          expect(result.include?(price * (1 - discount))).to be(true)
        end
      end
    end

    it 'contains sampled legal values across the supported operators' do
      samples = ->(interval) { [interval.lo, (interval.lo + interval.hi) / 2, interval.hi] }
      operands = [Dentaku::Interval.new(-2, 3), Dentaku::Interval.new(0, 1), Dentaku::Interval.new(10, 12)]

      operands.each do |a|
        operands.each do |b|
          %w[+ - *].each do |op|
            result = evaluate_interval("a #{op} b", a: a, b: b)
            samples.call(a).each do |av|
              samples.call(b).each do |bv|
                expect(result.include?(av.public_send(op, bv))).to be(true)
              end
            end
          end
        end
      end
    end
  end

  it 'is exposed at the module level' do
    result = Dentaku.evaluate_interval('a ^ 2', a: [-1, 2])
    expect(result.interval.lo).to eq(0.0)
    expect(result.interval.hi).to be >= 4
  end
end
