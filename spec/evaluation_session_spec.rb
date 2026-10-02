require 'spec_helper'
require 'dentaku'
require 'dentaku/calculator'

describe Dentaku::EvaluationSession do
  let(:calculator) { Dentaku::Calculator.new }

  describe 'suspending and resuming' do
    it 'suspends on the first unbound variable and reports it' do
      session = calculator.session('a + b')

      expect(session).to be_suspended
      expect(session).not_to be_completed
      expect(session).not_to be_failed
      expect(session.status).to eq(:suspended)
      expect(session.missing_variables).to eq(%w(a))
    end

    it 'resumes from where it stopped across multiple rounds' do
      session = calculator.session('a + b + c')

      session.resume(a: 1)
      expect(session).to be_suspended
      expect(session.missing_variables).to eq(%w(b))

      session.resume(b: 2)
      expect(session).to be_suspended
      expect(session.missing_variables).to eq(%w(c))

      session.resume(c: 3)
      expect(session).to be_completed
      expect(session.result).to eq(6)
    end

    it 'matches evaluate! given all inputs at once' do
      expression = 'IF(a > 1, b * 2, c) AND d'
      data = { a: 5, b: 3, c: 9, d: true }

      session = calculator.session(expression)
      data.each { |key, value| session.resume(key => value) } until session.completed?

      expect(session.result).to eq(calculator.evaluate!(expression, data))
    end

    it 'completes immediately when all data is given up front' do
      session = calculator.session('a * 2', a: 21)

      expect(session).to be_completed
      expect(session.result).to eq(42)
    end

    it 'accepts a pre-parsed AST' do
      session = calculator.session(calculator.ast('a + 1'))
      session.resume(a: 1)

      expect(session.result).to eq(2)
    end

    it 'flattens nested data like the calculator does' do
      session = calculator.session('user.age + 1')
      session.resume(user: { age: 30 })

      expect(session).to be_completed
      expect(session.result).to eq(31)
    end
  end

  describe 'short-circuiting' do
    it 'does not request variables from the unselected IF branch' do
      expect(calculator.session('IF(true, 1, missing)').result).to eq(1)
      expect(calculator.session('IF(false, missing, 2)').result).to eq(2)
    end

    it 'suspends on the IF predicate first' do
      session = calculator.session('IF(cond, a, b)')

      expect(session.missing_variables).to eq(%w(cond))
      session.resume(cond: false)
      expect(session.missing_variables).to eq(%w(b))
    end

    it 'does not request variables short-circuited by AND' do
      session = calculator.session('false AND missing')

      expect(session).to be_completed
      expect(session.result).to eq(false)
    end

    it 'does not request variables short-circuited by OR' do
      session = calculator.session('true OR missing')

      expect(session).to be_completed
      expect(session.result).to eq(true)
    end

    it 'requests the left operand of AND before the right one' do
      session = calculator.session('a AND b')

      expect(session.missing_variables).to eq(%w(a))
      session.resume(a: true)
      expect(session.missing_variables).to eq(%w(b))
    end
  end

  describe 'custom functions' do
    let(:calls) { [] }

    def add_recording_function(name, &block)
      record = calls
      calculator.add_function(name, :numeric, ->(x) { record << name; block.call(x) })
    end

    it 'does not re-run functions that already executed' do
      add_recording_function(:f) { |x| x * 2 }
      add_recording_function(:g) { |x| x + 1 }

      session = calculator.session('f(a) + g(b)')
      session.resume(a: 1)
      expect(calls).to eq(%i(f))

      session.resume(b: 2)
      expect(session).to be_completed
      expect(session.result).to eq(5)
      expect(calls).to eq(%i(f g))
    end

    it 'matches the call sequence of a single full evaluation' do
      add_recording_function(:f) { |x| x * 2 }
      add_recording_function(:g) { |x| x + 1 }

      session = calculator.session('f(a) + g(b) + f(a)')
      session.resume(a: 1)
      session.resume(b: 2)

      reference_calls = []
      reference = Dentaku::Calculator.new
      reference.add_function(:f, :numeric, ->(x) { reference_calls << :f; x * 2 })
      reference.add_function(:g, :numeric, ->(x) { reference_calls << :g; x + 1 })
      expected = reference.evaluate!('f(a) + g(b) + f(a)', a: 1, b: 2)

      expect(session.result).to eq(expected)
      expect(calls).to eq(reference_calls)
    end

    it 'does not re-run functions across several suspensions' do
      add_recording_function(:f) { |x| x }
      add_recording_function(:g) { |x| x }
      add_recording_function(:h) { |x| x }

      session = calculator.session('f(a) + g(b) + h(c)')
      session.resume(a: 1)
      session.resume(b: 2)
      session.resume(c: 3)

      expect(session.result).to eq(6)
      expect(calls).to eq(%i(f g h))
    end

    it 're-runs volatile functions on resume' do
      count = 0
      calculator.add_function(:vol, :numeric, ->(x) { count += 1; x }, volatile: true)

      session = calculator.session('vol(a) + b')
      session.resume(a: 1)
      session.resume(b: 2)

      expect(session.result).to eq(3)
      expect(count).to eq(2)
    end
  end

  describe 'variable values' do
    it 'treats an explicit nil as a provided value' do
      session = calculator.session('a', a: nil)

      expect(session).to be_completed
      expect(session.result).to be_nil
    end

    it 'suspends when no value was provided' do
      session = calculator.session('a')

      expect(session).to be_suspended
      expect(session.missing_variables).to eq(%w(a))
    end

    it 'fails when a Proc callback raises' do
      session = calculator.session('a', a: -> { raise 'boom' })

      expect(session).to be_failed
      expect(session.error).to be_a(Dentaku::ResolutionError)
      expect(session.error.identifier).to eq('a')
      expect(session.error.cause).to be_a(RuntimeError)
      expect(session.error.cause.message).to eq('boom')
    end

    it 'does not re-fetch Proc values on resume' do
      fetches = 0
      session = calculator.session('a + b')
      session.resume(a: -> { fetches += 1; 1 })
      session.resume(b: 2)

      expect(session.result).to eq(3)
      expect(fetches).to eq(1)
    end
  end

  describe 'failure' do
    it 'stops at the identifier whose resolution failed' do
      calls = []
      calculator.add_function(:g, :numeric, ->(x) { calls << x; x })

      session = calculator.session('g(a) + b')
      session.resume(a: 5)
      session.resume(b: -> { raise 'db down' })

      expect(session).to be_failed
      expect(session.error).to be_a(Dentaku::ResolutionError)
      expect(session.error.identifier).to eq('b')
      expect(calls).to eq([5])
    end

    it 'fails on evaluation errors after all variables are bound' do
      session = calculator.session('a / b')
      session.resume(a: 1)
      session.resume(b: 0)

      expect(session).to be_failed
      expect(session.error).to be_a(Dentaku::ZeroDivisionError)
    end
  end

  describe 'lifecycle' do
    it 'rejects resuming a completed session' do
      session = calculator.session('1 + 1')

      expect(session).to be_completed
      expect { session.resume }.to raise_error(Dentaku::SessionStateError) do |error|
        expect(error.state).to eq(:completed)
      end
    end

    it 'rejects resuming a failed session' do
      session = calculator.session('a', a: -> { raise 'boom' })

      expect(session).to be_failed
      expect { session.resume(a: 1) }.to raise_error(Dentaku::SessionStateError) do |error|
        expect(error.state).to eq(:failed)
      end
    end
  end

  describe 'isolation' do
    it 'does not share provided values between sessions' do
      first = calculator.session('x + y')
      second = calculator.session('x + y')

      first.resume(x: 1)

      expect(first.missing_variables).to eq(%w(y))
      expect(second.missing_variables).to eq(%w(x))
    end

    it 'does not leak session values into the calculator memory' do
      session = calculator.session('x + 1')
      session.resume(x: 1)

      expect(session.result).to eq(2)
      expect(calculator.memory).to be_empty
    end

    it 'does not share memoized function results between sessions' do
      calls = 0
      calculator.add_function(:f, :numeric, ->(x) { calls += 1; x })

      calculator.session('f(a)', a: 1)
      calculator.session('f(a)', a: 1)

      expect(calls).to eq(2)
    end
  end
end
