require 'spec_helper'
require 'dentaku'

describe 'Dentaku array values (batch evaluation)' do
  let(:calculator) { Dentaku::Calculator.new }

  describe 'scalar broadcasting' do
    it 'broadcasts a scalar over a one-dimensional array' do
      expect(calculator.evaluate!('a + 1', a: [1, 2, 3])).to eq([2, 3, 4])
    end

    it 'broadcasts arrays against scalars on either side' do
      expect(calculator.evaluate!('2 * a', a: [1, 2, 3])).to eq([2, 4, 6])
    end

    it 'broadcasts on comparison and logical operators' do
      expect(calculator.evaluate!('a > 1', a: [1, 2, 3])).to eq([false, true, true])
    end

    it 'broadcasts into element-wise functions' do
      expect(calculator.evaluate!('ROUND(a, 1)', a: [1.23, 2.56])).to eq([1.2, 2.6])
    end

    it 'broadcasts around math functions on every axis' do
      result = calculator.evaluate!('a * SQRT(b)', a: [[2], [3]], b: [[4, 9]])
      expect(result).to eq([[4.0, 6.0], [6.0, 9.0]])
    end
  end

  describe 'trailing-dimension alignment' do
    it 'broadcasts a 2x1 price array against a 1x3 discount array into 2x3' do
      result = calculator.evaluate!(
        'price * discount',
        price: [[100], [200]],
        discount: [[0.9, 0.8, 0.7]]
      )
      expect(result).to eq([[90.0, 80.0, 70.0], [180.0, 160.0, 140.0]])
    end

    it 'aligns a row vector and a column vector without materializing first' do
      result = calculator.evaluate!('rows + cols', rows: [[1], [2], [3]], cols: [[10, 20]])
      expect(result).to eq([[11, 21], [12, 22], [13, 23]])
    end

    it 'rejects conflicting trailing dimensions' do
      expect {
        calculator.evaluate!('a + b', a: [1, 2, 3], b: [1, 2])
      }.to raise_error(Dentaku::ShapeError) { |error|
        expect(error.axis).to eq(0)
        expect(error.left_dimension).to eq(3)
        expect(error.right_dimension).to eq(2)
      }
    end

    it 'rejects conflicting inner dimensions while accepting matching outer ones' do
      expect {
        calculator.evaluate!('a + b', a: [[1, 2], [3, 4]], b: [[[1, 2, 3]]])
      }.to raise_error(Dentaku::ShapeError)
    end
  end

  describe 'empty dimensions and singleton axes' do
    it 'produces an empty array when broadcasting against an empty axis' do
      expect(calculator.evaluate!('a + 1', a: [])).to eq([])
    end

    it 'preserves an empty inner dimension through multi-dimensional broadcast' do
      expect(calculator.evaluate!('a * b', a: [[], []], b: [[1, 2, 3]])).to eq([[], []])
    end

    it 'treats size-one axes as repeatable on every dimension' do
      result = calculator.evaluate!('a + b', a: [[[1]]], b: [[[10, 20], [30, 40]]])
      expect(result).to eq([[[11, 21], [31, 41]]])
    end
  end

  describe 'nested ragged arrays' do
    it 'keeps irregular inner arrays opaque and applies the operation per outer member' do
      result = calculator.evaluate!('a + 1', a: [[1, 2], [3]])
      expect(result).to eq([[2, 3], [4]])
    end

    it 'pairs ragged members position-wise when outer axes agree' do
      result = calculator.evaluate!('a + b', a: [[1, 2], [3]], b: [[10], [20, 30]])
      expect(result).to eq([[11, 12], [23, 33]])
    end

    it 'selects branches leaf by leaf through an irregular predicate' do
      result = calculator.evaluate!(
        'IF(mask, on, off)',
        mask: [[true, false], [true]],
        on: [[1, 2], [3]],
        off: [[10, 20], [30]]
      )
      expect(result).to eq([[1, 20], [3]])
    end

    it 'does not trigger unselected leaves inside a ragged predicate' do
      seen = []
      calculator.add_function(:hit, :numeric, ->(x) { seen << x; 99 }, nil, volatile: true)

      result = calculator.evaluate!(
        'IF(mask, values, hit(values))',
        mask: [[true, false], [true]],
        values: [[1, 2], [3]]
      )
      expect(result).to eq([[1, 99], [3]])
      expect(seen).to eq([2])
    end
  end

  describe 'shape checks before side effects' do
    it 'validates shapes before invoking a side-effecting function' do
      calls = 0
      calculator.add_function(:bump, :numeric, ->(x) { calls += 1; x }, volatile: true)

      expect {
        calculator.evaluate!('bump(a) + bump(b)', a: [1, 2, 3], b: [1, 2])
      }.to raise_error(Dentaku::ShapeError)
      expect(calls).to eq(0)
    end

    it 'detects a nested shape conflict before running nested side effects' do
      calls = []
      calculator.add_function(:bump, :numeric, ->(x) { calls << x; x }, nil, volatile: true)

      expect {
        calculator.evaluate!('ABS(bump(a)) + bump(b)', a: [1, 2, 3], b: [1, 2])
      }.to raise_error(Dentaku::ShapeError)
      expect(calls).to eq([])
    end

    it 'validates shapes of element-wise functions before any position runs' do
      calls = 0
      calculator.add_function(:tick, :numeric, ->(x) { calls += 1; x }, volatile: true)

      expect {
        calculator.evaluate!('tick(a)', a: [1, 2, 3], b: 1)
      }.not_to raise_error
      expect(calls).to eq(3)
    end
  end

  describe 'IF element selection' do
    it 'selects the branch for each element' do
      result = calculator.evaluate!(
        'IF(mask, on, off)',
        mask: [true, false, true], on: [1, 2, 3], off: [10, 20, 30]
      )
      expect(result).to eq([1, 20, 3])
    end

    it 'does not trigger division by zero on unselected elements' do
      result = calculator.evaluate!(
        'IF(mask, price / divisor, 0)',
        mask: [true, false, true], price: [10, 20, 30], divisor: [2, 0, 3]
      )
      expect(result).to eq([5, 0, 10])
    end

    it 'does not call a side-effecting function on unselected elements' do
      calls = []
      calculator.add_function(:boom, :numeric, ->(x) { calls << x; x * 10 }, volatile: true)

      result = calculator.evaluate!(
        'IF(mask, boom(price), -1)',
        mask: [true, false, true], price: [1, 2, 3]
      )
      expect(result).to eq([10, -1, 30])
      expect(calls).to eq([1, 3])
    end

    it 'broadcasts a scalar predicate branch over the array' do
      expect(calculator.evaluate!('IF(mask, a, 0)', mask: [true, false], a: [5, 6])).to eq([5, 0])
    end

    it 'propagates the batch shape through functions and nested arithmetic' do
      expect(calculator.evaluate!('ABS(IF(mask, a, -a))', mask: [true, false], a: [3, 5])).to eq([3, 5])
      expect(calculator.evaluate!('a + IF(mask, 1, 2)', mask: [true, false, false], a: [10, 20, 30])).to eq([11, 22, 32])
      expect(calculator.evaluate!('IF(a > 2, 100, 0)', a: [1, 2, 3])).to eq([0, 0, 100])
    end

    it 'does not run an unselected side effect even when its argument is an array' do
      calls = []
      calculator.add_function(:hit, :numeric, ->(x) { calls << x; 99 }, nil, volatile: true)
      calculator.evaluate!('IF(flag, 1, hit(x))', flag: true, x: [1, 2, 3])
      expect(calls).to eq([])
    end
  end

  describe 'indexed partial errors' do
    it 'keeps legal results and reports the failing index in strict mode' do
      error = nil
      begin
        calculator.evaluate!('a / b', a: [10, 20, 30], b: [2, 0, 3])
      rescue Dentaku::BatchError => batch
        error = batch
      end

      expect(error).to be_a(Dentaku::BatchError)
      expect(error.partial_results).to eq([5, nil, 10])
      expect(error.index_errors.map(&:first)).to eq([[1]])
      expect(error.index_errors.map(&:last)).to all(be_a(Dentaku::ZeroDivisionError))
    end

    it 'preserves multi-dimensional indices' do
      error = begin
        calculator.evaluate!('a / b', a: [[10, 20], [30, 40]], b: [[2, 0], [0, 5]])
      rescue Dentaku::BatchError => batch
        batch
      end

      expect(error.partial_results).to eq([[5, nil], [nil, 8]])
      expect(error.index_errors.map(&:first)).to contain_exactly([0, 1], [1, 0])
    end

    it 'returns legal results with nil at failed positions in permissive mode' do
      reported = []
      result = calculator.evaluate('a / b', a: [10, 20, 30], b: [2, 0, 3]) do |_expr, cause, index, partial|
        reported << [index, cause.class, partial]
      end

      expect(result).to eq([5, nil, 10])
      expect(reported.map(&:first)).to eq([[1]])
      expect(reported.map { |entry| entry[1] }).to eq([Dentaku::ZeroDivisionError])
    end
  end

  describe 'element-wise versus whole-array function declarations' do
    it 'distinguishes per-element calls from whole-array calls at registration' do
      calculator.add_function(:doubled, :numeric, ->(x) { x * 2 }, vector_mode: :elementwise)
      calculator.add_function(:joined, :string, ->(values) { values.join('-') }, vector_mode: :array)

      expect(calculator.evaluate!('doubled(a)', a: [1, 2, 3])).to eq([2, 4, 6])
      expect(calculator.evaluate!('joined(a)', a: [1, 2, 3])).to eq('1-2-3')
    end

    it 'uses a counting function to prove a mask limits the call range' do
      seen = []
      calculator.add_function(
        :counted,
        :numeric,
        ->(x) { seen << x; x },
        nil,
        volatile: true,
        vector_mode: :elementwise
      )

      calculator.evaluate!(
        'IF(mask, counted(values), 0)',
        mask: [false, true, false, true],
        values: [10, 20, 30, 40]
      )

      expect(seen).to eq([20, 40])
      expect(seen.length).to eq(2)
    end

    it 'aggregates masked counter hits with a counting function' do
      runs = 0
      calculator.add_function(
        :register_hit,
        :numeric,
        ->(x) { runs += 1; 1 },
        nil,
        volatile: true,
        vector_mode: :elementwise
      )

      total = calculator.evaluate!(
        'SUM(IF(mask, register_hit(values), 0))',
        mask: [false, true, false, true],
        values: [1, 2, 3, 4]
      )
      expect(total).to eq(2)
      expect(runs).to eq(2)
    end

    it 'passes whole arrays to aggregate built-ins without broadcasting them' do
      expect(calculator.evaluate!('SUM(a)', a: [1, 2, 3])).to eq(6)
      expect(calculator.evaluate!('AVG(a)', a: [2, 4])).to eq(3)
    end
  end

  describe 'array literals remain value collections' do
    it 'concatenates and differences literal lists' do
      expect(calculator.evaluate!('{1, 2} + {3}')).to eq([1, 2, 3])
      expect(calculator.evaluate!('{1, 2, 3} - {2}')).to eq([1, 3])
    end
  end
end
