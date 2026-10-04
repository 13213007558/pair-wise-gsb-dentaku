require 'spec_helper'
require 'dentaku'

describe Dentaku::Calculator, '#static_check' do
  let(:calculator) { described_class.new }

  def check(expression, types = {})
    calculator.static_check(expression, types)
  end

  it 'derives scalar and nil result types' do
    expect(check('1 + 2').type).to eq(:numeric)
    expect(check('"a" = "b"').type).to eq(:logical)
    expect(check('2024-01-02 + 1').type).to eq(:datetime)
    expect(check('null').type).to eq(:nil)
  end

  it 'derives parameterized array and element types' do
    result = check('MAP(items, item, item + 1)', items: { array: :numeric })
    expect(result.type).to eq({ array: :numeric })
    expect(result).to be_valid
    expect(check('{}').type).to eq({ array: :unknown })
  end

  it 'reports the original range of a date-plus-string operand' do
    expression = 'IF(ready, 2024-01-01 + 1, 2024-01-01 + "x")'
    result = check(expression, ready: :logical)

    expect(result).not_to be_valid
    conflict = result.conflicts.first
    expect(conflict.actual).to eq(:string)
    expect(conflict.range.start_pos.offset).to eq(expression.index('"x"'))
    expect(conflict.range.end_pos.offset).to eq(expression.index('"x"') + 3)
  end

  it 'forms a union from different IF branch result types' do
    result = check('IF(ready, 1, "one")', ready: :logical)

    expect(result).to be_valid
    expect(result.type).to contain_exactly(:numeric, :string)
  end

  it 'does not confuse an unknown variable with a definite type conflict' do
    expect(check('unknown + 1')).to be_valid
    expect(check('1 + "x"')).not_to be_valid
  end

  it 'checks both IF branches even though one runtime value does not execute' do
    expression = 'IF(ready, 1, 2 + "x")'
    result = check(expression, ready: :logical)

    expect(result).not_to be_valid
    offending = result.conflicts.find { |conflict| conflict.actual == :string }
    expect(offending.range.start_pos.offset).to eq(expression.index('"x"'))
  end

  it 'checks nested array element types and array index types' do
    result = check('MAP(rows, row, row[0] + 1)', rows: { array: { array: :string } })
    expect(result).not_to be_valid
    offending = result.conflicts.find { |conflict| conflict.actual == :string }
    expect(offending.range.start_pos.offset).to eq(15)

    result = check('numbers["zero"]', numbers: { array: :numeric })
    expect(result).not_to be_valid
    offending = result.conflicts.find { |conflict| conflict.actual == :string }
    expect(offending.actual).to eq(:string)
  end

  it 'binds enum local variables to the declared collection element type' do
    result = check('MAP(items, item, item + "x")', items: { array: :numeric })

    expect(result).not_to be_valid
    offending = result.conflicts.find { |conflict| conflict.actual == :string }
    expect(offending.actual).to eq(:string)
  end

  it 'checks REDUCE local variables in the accumulator expression' do
    result = check('REDUCE(numbers, memo, item, memo + "x", 0)', numbers: { array: :numeric })

    expect(result).not_to be_valid
    expect(result.conflicts.first.actual).to eq(:string)
  end

  it 'uses custom function signatures without invoking the implementation' do
    called = false
    calculator.add_function(
      :boom,
      :numeric,
      -> { called = true; raise 'must not be called' },
      signatures: [{ params: [], return: :numeric }]
    )

    result = check('BOOM() + "x"')
    expect(result).not_to be_valid
    expect(called).to be(false)
  end

  it 'reports no matching custom function signature' do
    calculator.add_function(
      :lookup,
      :numeric,
      ->(value) { value },
      signatures: [
        { params: [:numeric], return: :string },
        { params: [:string], return: :numeric }
      ]
    )

    result = check('LOOKUP(true)')
    expect(result).not_to be_valid
    expect(result.conflicts.first.message).to include('no matching')
  end

  it 'reports genuine overload ambiguity' do
    calculator.add_function(
      :choose,
      :numeric,
      ->(value) { value },
      signatures: [
        { params: [{ array: :numeric }], return: :numeric },
        { params: [{ array: :logical }], return: :numeric }
      ]
    )

    result = check('CHOOSE(IF(ready, {1}, {true}))', ready: :logical)
    expect(result).not_to be_valid
    expect(result.conflicts.first.message).to include('ambiguous')
  end

  it 'keeps unknown overload arguments separate from ambiguity' do
    calculator.add_function(
      :lookup,
      :numeric,
      ->(value) { value },
      signatures: [
        { params: [:numeric], return: :string },
        { params: [:string], return: :numeric }
      ]
    )

    result = check('LOOKUP(unknown)')
    expect(result).to be_valid
    expect(result.type).to contain_exactly(:numeric, :string)
  end

  it 'checks built-in enum functions with their predicate result' do
    result = check('ALL(items, item, item + 1)', items: { array: :numeric })

    expect(result).not_to be_valid
    expect(result.conflicts.first.message).to include('logical')
  end
end
