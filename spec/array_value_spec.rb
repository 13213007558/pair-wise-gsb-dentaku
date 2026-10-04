require 'spec_helper'
require 'dentaku'
require 'dentaku/calculator'

describe 'array values' do
  let(:calculator) { Dentaku::Calculator.new }

  it 'broadcasts scalars and aligns array dimensions by their trailing axes' do
    prices = [[100], [200]]
    discounts = [[0.1, 0.2, 0.3]]

    expect(calculator.evaluate!('prices * (1 - discounts)', prices: prices, discounts: discounts))
      .to eq([[90.0, 80.0, 70.0], [180.0, 160.0, 140.0]])
    expect(calculator.evaluate!('{1, 2} + 10')).to eq([11, 12])
    expect(calculator.evaluate!('{1, 2} + {10, 20}')).to eq([11, 22])
  end

  it 'broadcasts single-element axes' do
    expect(calculator.evaluate!('a + b', a: [[1], [2]], b: [[10, 20, 30]]))
      .to eq([[11, 21, 31], [12, 22, 32]])
  end

  it 'defines zero-length dimensions as empty and rejects incompatible nonzero dimensions' do
    expect(calculator.evaluate!('empty + 10', empty: [])).to eq([])
    expect { calculator.evaluate!('a + b', a: [1, 2], b: [1, 2, 3]) }
      .to raise_error(Dentaku::ShapeMismatch, 'array shapes are not compatible: [2], [3]')
    expect { calculator.evaluate!('a + b', a: [], b: [1, 2]) }
      .to raise_error(Dentaku::ShapeMismatch, 'array shapes are not compatible: [0], [2]')
  end

  it 'keeps irregular arrays opaque to whole-array functions instead of broadcasting them' do
    expect(calculator.evaluate!('SUM(values)', values: [[1, 2], [3]])).to eq(6)
    expect { calculator.evaluate!('ABS(values)', values: [[1, 2], [3]]) }
      .to raise_error(Dentaku::ArgumentError)
  end

  it 'evaluates IF independently at every element without evaluating the unselected branch' do
    result = calculator.evaluate!(
      'IF(mask, IF(mask, safe, 1 / 0), 9)',
      mask: [true, false],
      safe: [2, 4]
    )

    expect(result).to eq([2, 9])
  end

  it 'retains the index of element errors while preserving other results' do
    calculator.add_function(:risk, :numeric, ->(x) { raise 'boom' if x.zero?; 10 / x },
                            array_mode: :elementwise, volatile: true)

    begin
      calculator.evaluate!('IF(mask, risk(values), 9)', mask: [true, true, false], values: [1, 0, 4])
    rescue Dentaku::ArrayEvaluationError => error
      expect(error.indices).to eq([[1]])
      expect(error.partial_results).to eq([10, nil, 9])
    else
      raise 'expected an array evaluation error'
    end
  end

  it 'declares whole-array functions separately from elementwise functions' do
    calculator.add_function(:whole_count, :numeric, ->(values) { values.length }, array_mode: :whole)
    calculator.add_function(:label, :string, ->(value) { "v#{value}" }, array_mode: :elementwise)

    expect(calculator.evaluate!('WHOLE_COUNT(values)', values: [1, 2, 3])).to eq(3)
    expect(calculator.evaluate!('LABEL(values)', values: [1, 2, 3])).to eq(['v1', 'v2', 'v3'])
  end

  it 'checks shape conflicts before invoking a side-effecting function' do
    calls = 0
    calculator.add_function(:observed, :numeric, ->(value) { calls += 1; value },
                            array_mode: :elementwise, volatile: true)

    expect do
      calculator.evaluate!('OBSERVED(a) + b', a: [1, 2], b: [1, 2, 3])
    end.to raise_error(Dentaku::ShapeMismatch)
    expect(calls).to eq(0)
  end

  it 'proves that a mask restricts function invocation rather than evaluating every branch' do
    calls = 0
    mask = [true, false, true]
    values = [2, 0, 4]
    calculator.add_function(:observed, :numeric, ->(value) { calls += 1; value + 10 },
                            array_mode: :elementwise, volatile: true)

    result = calculator.evaluate!('IF(mask, OBSERVED(values), 0)', mask: mask, values: values)

    expect(result).to eq([12, 0, 14])
    expect(calls).to eq(2)
    expect(calculator.evaluate!('COUNT(mask)', mask: mask)).to eq(3)
  end

  it 'returns partial results from non-strict evaluation' do
    calculator.add_function(:risk, :numeric, ->(x) { raise 'boom' if x.zero?; 10 / x },
                            array_mode: :elementwise)

    result = calculator.evaluate('IF(mask, risk(values), 9)', mask: [true, true, false], values: [1, 0, 4])

    expect(result).to eq([10, nil, 9])
  end
end
