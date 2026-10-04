require 'spec_helper'
require 'dentaku'

RSpec.describe Dentaku::CalculationSession do
  let(:calculator) { Dentaku::Calculator.new }

  it 'returns only outputs changed by an input update' do
    session = calculator.session(
      { output: 'watched + 1' },
      { watched: 1, ignored: 2 }
    )

    expect(session.results).to eq('output' => 2)
    expect(session.update(ignored: 3)).to eq({})
    expect(session.update(watched: 2)).to eq('output' => 3)
  end

  it 'does not execute a formula after an unrelated input changes' do
    calls = 0
    calculator.add_function(:counted, :numeric, ->(value) { calls += 1; value * 2 })
    session = calculator.session(
      { output: 'counted(used) + 1' },
      { used: 2, ignored: 0 }
    )

    expect(calls).to eq(1)
    expect(session.update(ignored: 1)).to eq({})
    expect(calls).to eq(1)

    expect(session.update(used: 3)).to eq('output' => 7)
    expect(calls).to eq(2)
  end

  it 'does not invalidate siblings through an unchanged shared formula' do
    calls = Hash.new(0)
    calculator.add_function(:counted, :numeric, ->(name, value) { calls[name] += 1; value })
    session = calculator.session(
      {
        shared: 'base',
        first: 'counted("first", shared)',
        second: 'counted("second", shared)',
        trigger: 'input'
      },
      { base: 1, input: 1, ignored: 0 }
    )

    expect(session.update(input: 2)).to eq('trigger' => 2)
    expect(calls).to eq('first' => 1, 'second' => 1)
  end

  it 'tracks only the IF branch actually evaluated and switches subscriptions' do
    session = calculator.session(
      { output: 'IF(flag, left, right)' },
      { flag: true, left: 1, right: 2 }
    )

    expect(session.dependencies('output')).to eq(%w[flag left])
    expect(session.update(right: 3)).to eq({})
    expect(session.dependencies('output')).to eq(%w[flag left])

    expect(session.update(flag: false)).to eq('output' => 3)
    expect(session.dependencies('output')).to eq(%w[flag right])

    expect(session.update(left: 9)).to eq({})
    expect(session.update(right: 4)).to eq('output' => 4)
  end

  it 'removes dependencies from a branch after the condition flips' do
    session = calculator.session(
      { child: 'IF(flag, left, deleted)', parent: 'child + 1' },
      { flag: true, left: 10, deleted: 20 }
    )

    expect(session.dependencies('child')).to eq(%w[flag left])
    expect(session.dependencies('parent')).to eq(['child'])

    session.update(flag: false)
    expect(session.dependencies('child')).to eq(%w[flag deleted])
    expect(session.update(left: 99)).to eq({})
  end

  it 'tracks the selected CASE branch' do
    session = calculator.session(
      { output: 'CASE choice WHEN 1 THEN one WHEN 2 THEN two ELSE three END' },
      { choice: 1, one: 10, two: 20, three: 30 }
    )

    expect(session.dependencies('output')).to eq(%w[choice one])
    expect(session.update(choice: 2)).to eq('output' => 20)
    expect(session.dependencies('output')).to eq(%w[choice two])
  end

  it 'invalidates results when a formula definition changes' do
    session = calculator.session(
      { output: 'input * 2' },
      { input: 3 }
    )

    expect(session.results).to eq('output' => 6)
    session.store_formula('output', 'input * 3')
    expect(session.last_changes).to eq('output' => 9)
  end

  it 'invalidates results after a custom function implementation changes' do
    calculator.add_function(:custom_fn, :numeric, ->(value) { value + 1 })
    session = calculator.session({ output: 'custom_fn(1)' }, {})
    expect(session.results).to eq('output' => 2)

    calculator.add_function(:custom_fn, :numeric, ->(value) { value + 10 })
    expect(session.update).to eq('output' => 11)
  end

  it 'runs volatile functions every round even when no input changes' do
    calls = 0
    calculator.add_function(:clock, :numeric, -> { calls += 1; calls }, volatile: true)
    session = calculator.session({ output: 'clock()' }, {})

    expect(session.results).to eq('output' => 1)
    expect(session.update).to eq('output' => 2)
    expect(session.update).to eq('output' => 3)
  end

  it 'waits for a volatile dependency before evaluating a dependent formula' do
    clock = 0
    calculator.add_function(:clock, :numeric, -> { clock += 1 }, volatile: true)
    session = calculator.session(
      { base: 'clock()', output: 'base + 1' },
      {}
    )

    expect(session.results).to eq('base' => 1, 'output' => 2)
    expect(session.update).to eq('base' => 2, 'output' => 3)
  end

  it 'does not run volatile code on an untaken branch' do
    calls = 0
    calculator.add_function(:clock, :numeric, -> { calls += 1; calls }, volatile: true)
    session = calculator.session(
      { output: 'IF(flag, clock(), 1)' },
      { flag: false }
    )

    expect(calls).to eq(0)
    expect(session.update).to eq({})
    expect(calls).to eq(0)
  end

  it 'propagates errors after deleting a variable and recovers when it returns' do
    session = calculator.session(
      { child: 'value + 1', parent: 'child + 1' },
      { value: 1 }
    )

    expect(session.results).to eq('child' => 2, 'parent' => 3)
    expect(session.delete_variable(:value)).to eq('child' => :undefined, 'parent' => :undefined)
    expect(session.results).to eq('child' => :undefined, 'parent' => :undefined)
    expect(session.errors.keys).to match_array(%w[child parent])

    expect(session.update(value: 2)).to eq('child' => 3, 'parent' => 4)
  end

  it 'tracks active cycles dynamically as conditions change' do
    session = calculator.session(
      {
        enabled: 'flag',
        first: 'IF(enabled, second, 1)',
        second: 'first + 1'
      },
      { flag: false }
    )

    expect(session.results).to eq('enabled' => false, 'first' => 1, 'second' => 2)
    expect(session.update(flag: true)).to eq('enabled' => true, 'first' => :undefined, 'second' => :undefined)
    expect(session.errors['first']).to be_a(Dentaku::CircularDependencyError)

    expect(session.update(flag: false)).to eq('enabled' => false, 'first' => 1, 'second' => 2)
    expect(session.errors).to eq({})
  end

  it 'matches full evaluation after a sequence of updates' do
    formulas = {
      selected: 'IF(flag, left, right)',
      derived: 'selected + watched',
      unused_branch: 'IF(flag, missing, 1)'
    }
    session = calculator.session(
      formulas,
      { flag: true, left: 2, right: 3, watched: 10, ignored: 0 }
    )

    changes = [
      session.update(ignored: 1),
      session.update(right: 4),
      session.update(flag: false),
      session.update(left: 100),
      session.update(right: 5)
    ]

    expect(changes).to eq([
      {},
      {},
      { 'selected' => 4, 'derived' => 14, 'unused_branch' => 1 },
      {},
      { 'selected' => 5, 'derived' => 15 }
    ])
    expect(session.results.transform_keys(&:to_sym)).to eq(Dentaku::Calculator.new.tap do |fresh|
      fresh.store(flag: false, left: 100, right: 5, watched: 10, ignored: 1)
    end.solve(formulas))
  end
end
