require 'spec_helper'
require 'dentaku'

describe Dentaku::CalculationSession do
  let(:calculator) { Dentaku::Calculator.new }

  def register_calls(name, calls)
    calculator.add_function(name, :numeric, ->(value) {
      calls << value
      value
    })
  end

  it 'continues from the first missing variable without rerunning functions' do
    calls = []
    register_calls(:log, calls)
    expression = 'log(a) + log(b) + log(c)'
    direct = calculator.evaluate!(expression, a: 1, b: 2, c: 3)
    calls.clear

    session = calculator.start_session(expression)
    expect(session).to be_pending
    expect(session.required_variables).to eq(['a'])
    expect(calls).to eq([])

    expect(session.resume!(a: 1).required_variables).to eq(['b'])
    expect(session.resume!(b: 2).required_variables).to eq(['c'])
    expect(calls).to eq([1, 2])

    expect(session.resume!(c: 3).result).to eq(direct)
    expect(calls).to eq([1, 2, 3])
  end

  it 'does not request variables from an unselected IF branch' do
    calls = []
    register_calls(:log, calls)

    session = calculator.start_session('IF(a, log(b), log(c))', a: true)
    expect(session.required_variables).to eq(['b'])
    expect(session.resume!(b: 10).result).to eq(10)
    expect(calls).to eq([10])

    other = calculator.start_session('IF(a, log(b), log(c))', a: false)
    expect(other.required_variables).to eq(['c'])
    expect(other.resume!(c: 20).result).to eq(20)
    expect(calls).to eq([10, 20])
  end

  it 'short-circuits function and operator forms of AND and OR' do
    calls = []
    register_calls(:log, calls)

    session = calculator.start_session('AND(false, log(a))')
    expect(session.result).to eq(false)

    session = calculator.start_session('OR(true, log(a))')
    expect(session.result).to eq(true)

    session = calculator.start_session('false AND log(a)')
    expect(session.result).to eq(false)

    session = calculator.start_session('true OR log(a)')
    expect(session.result).to eq(true)
    expect(calls).to eq([])
  end

  it 'requests only the operand that can decide an unresolved AND or OR' do
    session = calculator.start_session('a OR b')
    expect(session.required_variables).to eq(['a'])
    expect(session.resume!(a: true).result).to eq(true)

    session = calculator.start_session('a AND b')
    expect(session.required_variables).to eq(['a'])
    expect(session.resume!(a: false).result).to eq(false)

    session = calculator.start_session('a OR b')
    session.resume!(a: false)
    expect(session.required_variables).to eq(['b'])
  end

  it 'keeps function dependency pruning in argument order' do
    expect(calculator.dependencies('AND(false, a)')).to eq([])
    expect(calculator.dependencies('OR(true, a)')).to eq([])
    expect(calculator.dependencies('AND(a, false)')).to eq([])
    expect(calculator.dependencies('OR(a, true)')).to eq([])
    expect(calculator.evaluate!('AND(false, a)')).to eq(false)
    expect(calculator.evaluate!('OR(true, a)')).to eq(true)
    expect(calculator.evaluate!('AND(a, false)')).to eq(false)
    expect(calculator.evaluate!('OR(a, true)')).to eq(true)
  end

  it 'treats provided nil as a value rather than another missing variable' do
    session = calculator.start_session('IF(a, b, c)', a: nil, b: nil)
    expect(session.required_variables).to eq(['c'])
    expect(session.resume!(c: nil).result).to be_nil

    session = calculator.start_session('AND(a, b)', a: nil)
    expect(session.result).to eq(false)
  end

  it 'keeps a lazily resolved nil value after resume' do
    resolutions = 0
    session = calculator.start_session('IF(a, b, c)', a: -> {
      resolutions += 1
      nil
    }, c: 7)

    expect(session.result).to eq(7)
    expect { session.result }.not_to change { resolutions }
  end

  it 'wraps a failure while resolving a variable and rejects another resume' do
    session = calculator.session('a + 1', a: -> { raise 'boom' })

    expect(session).to be_failed
    expect(session.error).to be_a(Dentaku::VariableResolutionError)
    expect(session.error.variable_name).to eq('a')
    expect(session.error.node.identifier).to eq('a')
    expect(session.error.cause.message).to eq('boom')
    expect { session.resume!(a: 1) }.to raise_error(Dentaku::SessionStateError)
  end

  it 'stops at the expression where a resumed value fails' do
    calls = []
    register_calls(:log, calls)
    session = calculator.start_session('log(a) + log(b)')

    session.resume!(a: 1)
    expect(session.resume(b: -> { raise 'boom' })).to be_failed
    expect(session.error).to be_a(Dentaku::VariableResolutionError)
    expect(session.error.variable_name).to eq('b')
    expect(session.error.node.identifier).to eq('b')
    expect(calls).to eq([1])
    expect { session.resume!(b: 2) }.to raise_error(Dentaku::SessionStateError)
  end

  it 'matches existing unbound operand resolution for infix AND and OR' do
    session = calculator.start_session('a OR true')
    expect(session.result).to eq(true)

    session = calculator.start_session('a AND false')
    expect(session.result).to eq(false)

    session = calculator.start_session('a OR b')
    expect(session.required_variables).to eq(['a'])
    expect(session.resume!(a: false).required_variables).to eq(['b'])
  end

  it 'matches unbound operand resolution for function AND and OR' do
    expect(calculator.start_session('AND(a, false)').result).to eq(false)
    expect(calculator.start_session('OR(a, true)').result).to eq(true)

    session = calculator.start_session('AND(a, b)')
    expect(session.required_variables).to eq(['a'])
    expect(session.resume!(a: true).required_variables).to eq(['b'])
  end

  it 'does not probe an unselected later operand that calls a function' do
    calls = []
    register_calls(:log, calls)

    session = calculator.start_session('AND(a, log(false))')
    expect(session.required_variables).to eq(['a'])
    expect(session.resume!(a: false).result).to eq(false)
    expect(calls).to eq([])

    session = calculator.start_session('a AND log(0) > 0')
    expect(session.required_variables).to eq(['a'])
    expect(session.resume!(a: false).result).to eq(false)
    expect(calls).to eq([])
  end

  it 'does not call a Proc from an unselected later operand' do
    called = false
    session = calculator.start_session('a OR b', b: -> {
      called = true
      false
    })

    expect(session.required_variables).to eq(['a'])
    expect(called).to eq(false)
    expect(session.resume!(a: true).result).to eq(true)
    expect(called).to eq(false)
  end

  it 'rejects resuming a completed session' do
    session = calculator.start_session('a + 1', a: 1)
    expect(session.result).to eq(2)
    expect { session.resume!(a: 2) }.to raise_error(Dentaku::SessionStateError)
  end

  it 'keeps mutable memory independent between sessions' do
    calculator.store(items: [1])
    first = calculator.start_session('items[0] + a')
    second = calculator.start_session('items[0] + a')

    first.resume!(a: 10)
    calculator.store(items: [9])

    expect(second.resume!(a: 20).result).to eq(21)
    expect(first.result).to eq(11)
  end

  it 'returns a failed session from the non-raising entry point' do
    session = calculator.session('a +')
    expect(session).to be_failed
    expect(session.error).to be_a(Dentaku::ParseError)
  end

  it 'marks runtime failures through the non-raising start and resume methods' do
    session = calculator.session('1 / a')
    expect(session.resume(a: 0)).to be_failed
    expect(session.error).to be_a(Dentaku::ZeroDivisionError)
    expect { session.resume!(a: 1) }.to raise_error(Dentaku::SessionStateError)
  end

  describe '#resume' do
    it 'returns the failed session instead of raising' do
      session = calculator.start_session('a + 1')
      failed = session.resume(a: -> { raise 'boom' })
      expect(failed).to be(session)
      expect(failed).to be_failed
    end
  end

end
