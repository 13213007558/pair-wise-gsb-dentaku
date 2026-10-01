require 'spec_helper'
require 'dentaku'

describe Dentaku::AST::Let do
  let(:calculator) { Dentaku::Calculator.new }

  it 'binds names for later bindings and the result' do
    result = calculator.evaluate!('LET(rate, 0.1, base, 100, base * rate)')
    expect(result).to eq(10)
  end

  it 'uses later bindings in preceding binding values and the result' do
    expect { calculator.ast('LET(a, 1, b, a + b, b)') }.to raise_error(
      Dentaku::ParseError,
      'LET() cannot reference b before it is bound at line 1, column 18'
    )
  end

  it 'reports the location of duplicate bindings' do
    expect { calculator.ast('LET(a, 1, a, 2, a)') }.to raise_error(
      Dentaku::ParseError,
      'LET() binds a more than once at line 1, column 11'
    ) do |error|
      expect(error.meta).to include(line: 1, column: 11, name: 'a')
    end
  end

  it 'reports the location of nested field-path binding conflicts' do
    expect { calculator.ast('LET(a, 1, a.b, 2, 1)') }.to raise_error(
      Dentaku::ParseError,
      'LET() bindings a.b and a conflict at line 1, column 11'
    ) do |error|
      expect(error.meta).to include(line: 1, column: 11, name: 'a.b', other_name: 'a')
    end
  end

  it 'reports the later binding when a nested path is bound first' do
    expect { calculator.ast('LET(a.b, 1, a, 2, 1)') }.to raise_error(
      Dentaku::ParseError,
      'LET() bindings a and a.b conflict at line 1, column 13'
    )
  end

  it 'still validates a LET nested inside another expression' do
    expect { calculator.ast('1 + LET(a, 1, b, a + b, b)') }.to raise_error(
      Dentaku::ParseError,
      /cannot reference b before it is bound at line 1, column 22/
    )
  end

  it 'reports positions relative to the original source around stripped comments' do
    expect { calculator.ast("LET(a, 1,\n  /* long comment */ a, 2, 1)") }.to raise_error(
      Dentaku::ParseError
    ) do |error|
      expect(error.meta).to include(line: 2, column: 22)
    end
  end

  it 'allows nested LET bindings to shadow outer bindings' do
    result = calculator.evaluate!('LET(a, 1, b, 2, LET(a, 10, a + b))')
    expect(result).to eq(12)
  end

  it 'works inside MAP' do
    result = calculator.evaluate!(
      'MAP(items, item, LET(tax, item * rate, item + tax))',
      items: [10, 20], rate: 0.1
    )
    expect(result).to eq([11, 22])
  end

  it 'works inside FILTER' do
    result = calculator.evaluate!(
      'FILTER(items, item, LET(limit, item * 2, limit > threshold))',
      items: [1, 5], threshold: 8
    )
    expect(result).to eq([5])
  end

  it 'scopes local names inside another LET' do
    result = calculator.evaluate!('LET(x, 1, LET(y, x + 2, y) + x)')
    expect(result).to eq(4)
  end

  it 'distinguishes free dependencies from local names' do
    formula = 'LET(rate, external_rate, base, base_input, base * rate + extra)'

    expect(calculator.identifiers(formula)).to match_array(%w(external_rate base_input extra))
    expect(calculator.dependencies(formula, external_rate: 0.1, base_input: 100)).to eq(['extra'])
  end

  it 'does not call functions while collecting identifiers' do
    calls = 0
    calculator.add_function(:counter, :numeric, ->(value) { calls += 1; value })
    formula = 'LET(x, counter(1), y, IF(counter(2) > 0, x, z), y)'

    expect(calculator.identifiers(formula)).to eq(['z'])
    expect(calculator.dependencies(formula)).to eq(['z'])
    expect(calls).to eq(0)
  end

  it 'evaluates each binding once every time the LET is entered' do
    calls = 0
    calculator.add_function(:counter, :numeric, ->(value) { calls += 1; value })

    formula = 'LET(x, counter(1), y, x + counter(2), x + y + x + y)'
    expect(calculator.evaluate!(formula)).to eq(8)
    expect(calls).to eq(2)

    calculator.evaluate!(formula)
    expect(calls).to eq(4)
  end

  it 'does not change calculator memory after normal evaluation' do
    calculator.store(persisted: 9)

    calculator.evaluate!('LET(local, 1, local + persisted)')

    expect(calculator.memory).to eq('persisted' => 9)
  end

  it 'restores calculator memory after an abnormal evaluation' do
    calculator.store(persisted: 9)

    expect do
      calculator.evaluate!('LET(local, 0, 1 / local)')
    end.to raise_error(Dentaku::ZeroDivisionError)

    expect(calculator.memory).to eq('persisted' => 9)
  end

  it 'restores calculator memory after an abnormal evaluation with identifier caching' do
    calculator.store(persisted: 9)
    Dentaku.enable_identifier_cache!

    expect do
      calculator.evaluate!('LET(local, 0, 1 / local)')
    end.to raise_error(Dentaku::ZeroDivisionError)

    expect(calculator.memory).to eq('persisted' => 9)
  ensure
    Dentaku.instance_variable_set(:@enable_identifier_caching, false)
  end

  it 'applies case sensitivity to local names' do
    sensitive = Dentaku::Calculator.new(case_sensitive: true)

    expect(sensitive.evaluate!('LET(Tax, 0.1, tax, 2, Tax + tax)')).to eq(2.1)
    expect { sensitive.ast('LET(Tax, 1, tax, 2, 1)') }.not_to raise_error
    expect { calculator.ast('LET(Tax, 1, tax, 2, 1)') }.to raise_error(Dentaku::ParseError, /binds tax more than once/)
  end

  it 'requires an odd number of arguments' do
    expect { calculator.ast('LET(a, 1, 2, 3)') }.to raise_error(
      Dentaku::ParseError,
      'LET() requires an odd number of arguments (name, value, ..., result)'
    )
  end

  it 'requires binding arguments to be identifiers' do
    expect { calculator.ast('LET(1, 2, 3)') }.to raise_error(
      Dentaku::ParseError,
      'LET() requires binding arguments to be identifiers'
    )
  end
end
