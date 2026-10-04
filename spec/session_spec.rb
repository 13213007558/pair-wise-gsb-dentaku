require 'spec_helper'
require 'dentaku'

RSpec.describe Dentaku::Session do
  let(:calculator) { Dentaku::Calculator.new }

  def full_solve(calculator, formulas, inputs)
    full_calculator = Dentaku::Calculator.new(case_sensitive: calculator.case_sensitive)
    full_calculator.store(inputs)
    full_calculator.solve(formulas).transform_keys(&:to_s)
  end

  describe 'incremental evaluation' do
    it 'does not re-evaluate formulas after an unrelated input change' do
      calls = Hash.new(0)
      calculator.add_function(:skip_read, :numeric, ->(name, value) { calls[name] += 1; value })

      session = calculator.session(
        out: 'IF(flag, skip_read("a", a + 1), skip_read("b", b + 10))',
        down: 'out + 1'
      )

      expect(session.update(flag: true, a: 1, b: 2, unused: 10)).to eq(out: 2, down: 3)
      expect(session.results).to eq(out: 2, down: 3)
      expect(session.dependencies(:out)).to eq(%w(flag a))
      expect(session.dependencies(:down)).to eq(['out'])
      expect(calls).to eq('a' => 1)

      expect(session.update(unused: 11)).to eq({})
      expect(session.results).to eq(out: 2, down: 3)
      expect(session.changed).to eq({})
      expect(calls).to eq('a' => 1)
    end

    it 'switches subscriptions when a condition changes and activates the new branch immediately' do
      calls = Hash.new(0)
      calculator.add_function(:branch_read, :numeric, ->(name, value) { calls[name] += 1; value })

      session = calculator.session(
        out: 'IF(flag, branch_read("a", a + 1), branch_read("b", b + 10))',
        down: 'out + 1'
      )
      session.update(flag: true, a: 1, b: 2)

      expect(session.update(flag: false)).to eq(out: 12, down: 13)
      expect(session.dependencies(:out)).to eq(%w(flag b))
      expect(session.dependencies(:down)).to eq(['out'])
      expect(calls).to eq('a' => 1, 'b' => 1)

      expect(session.update(a: 100)).to eq({})
      expect(session.changed).to eq({})
      expect(calls).to eq('a' => 1, 'b' => 1)

      expect(session.update(b: 20)).to eq(out: 30, down: 31)
      expect(session.changed).to eq(out: 30, down: 31)
      expect(calls).to eq('a' => 1, 'b' => 2)
    end

    it 'invalidates formulas whose definition changed' do
      session = calculator.session(out: 'x + 1')
      session.update(x: 1)

      session.update_formulas(out: 'x + 2')
      expect(session.update({})).to eq(out: 3)
      expect(session.changed).to eq(out: 3)
    end

    it 'invalidates formulas using a changed custom function version' do
      calls = 0
      calculator.add_function(:double, :numeric, ->(value) { calls += 1; value * 2 })
      session = calculator.session(out: 'double(x)')
      session.update(x: 3)
      expect(calls).to eq(1)

      calculator.add_function(:double, :numeric, ->(value) { value * 3 })
      expect(session.update({})).to eq(out: 9)
      expect(session.changed).to eq(out: 9)
    end

    it 'does not invalidate formulas when an unrelated custom function changes' do
      calls = 0
      calculator.add_function(:used, :numeric, ->(value) { calls += 1; value })
      session = calculator.session(out: 'used(x)')
      session.update(x: 3)

      calculator.add_function(:unused, :numeric, ->(value) { value + 1 })
      expect(session.update({})).to eq({})
      expect(session.changed).to eq({})
      expect(calls).to eq(1)
    end

    it 'runs volatile formulas during every calculation round' do
      calls = 0
      calculator.add_function(:tick, :numeric, -> { calls += 1; 1 }, volatile: true)
      session = calculator.session(value: 'tick()', dependent: 'value + 1')

      expect(session.update({})).to eq(value: 1, dependent: 2)
      expect(calls).to eq(1)

      expect(session.update({})).to eq({})
      expect(session.changed).to eq({})
      expect(calls).to eq(2)
    end

    it 're-evaluates formulas that read a volatile formula' do
      calculator.add_function(:tick, :numeric, -> { 41 }, volatile: true)
      session = calculator.session(value: 'tick()', dependent: 'value + 1')

      session.update({})
      expect(session.update({})).to eq({})
      expect(session.result(:dependent)).to eq(42)
    end

    it 'does not execute volatile calls in branches that are not taken' do
      calls = Hash.new(0)
      calculator.add_function(:volatile_branch_read, :numeric,
                              ->(name, value) { calls[name] += 1; value }, volatile: true)
      session = calculator.session(value: 'IF(flag, volatile_branch_read("on", 1), volatile_branch_read("off", 2))')

      expect(session.update(flag: true)).to eq(value: 1)
      expect(session.update(flag: true)).to eq({})
      expect(calls).to eq('on' => 2)
    end

    it 'matches permissive full evaluation for arrays with one invalid element' do
      session = calculator.session(values: ['1 + 1', 'x / 0'])
      expect(session.update(x: 0)).to eq(values: [2, :undefined])
      session.update_formulas(values: ['1 + 1', 'x / 1'])
      expect(session.update(x: 2)).to eq(values: [2, 2.0])
      expect(session.results).to eq(values: [2.0, 2.0])
    end

    it 'propagates unbound and runtime errors through actual reads only' do
      session = calculator.session(
        ratio: '10 / d',
        guarded: 'IF(d != 0, ratio, 0)',
        direct: 'ratio'
      )

      expect(session.update(d: 0)).to eq(ratio: :undefined, guarded: 0, direct: :undefined)
      current_formulas = {
        ratio: '10 / d',
        guarded: 'IF(d != 0, ratio, 0)',
        direct: 'ratio'
      }
      expect(session.results.transform_keys(&:to_s))
        .to eq(full_solve(calculator, current_formulas, session.inputs))
      expect(session.dependencies(:guarded)).to eq(['d'])
      expect(session.dependencies(:direct)).to eq(['ratio'])
      expect(session.error?(:ratio)).to be_a(Dentaku::ZeroDivisionError)

      expect(session.update(d: 2)).to eq(ratio: 5, guarded: 5, direct: 5)
      expect(session.dependencies(:guarded)).to eq(%w(d ratio))
      expect(session.results.transform_keys(&:to_s))
        .to eq(full_solve(calculator, current_formulas, session.inputs))
      expect(session.error?).to eq(false)
    end

    it 'propagates errors when deleting a read variable and recovers when it returns' do
      session = calculator.session(out: 'x + 1', unrelated: '1 + 1')
      session.update(x: 1)

      session.delete(:x)
      expect(session.update({})).to eq(out: :undefined)
      expect(session.error?(:out)).to be_a(Dentaku::UnboundVariableError)

      expect(session.update(x: 2)).to eq(out: 3)
      expect(session.results).to eq(out: 3, unrelated: 2)
      expect(session.error?).to eq(false)
    end

    it 'propagates and clears cyclic dependencies as they appear and disappear' do
      session = calculator.session(a: 'b + 1', b: '1', safe: '2 + 2')
      expect(session.update({})).to eq(a: 2, b: 1, safe: 4)
      expect(session.results).to eq(a: 2, b: 1, safe: 4)

      session.update_formulas(b: 'a + 1')
      expect(session.update({})).to eq(a: :undefined, b: :undefined)
      expect(session.results).to eq(a: :undefined, b: :undefined, safe: 4)
      expect(session.error?(:a)).to be_a(TSort::Cyclic)
      expect(session.error?(:b)).to be_a(TSort::Cyclic)
      expect(session.error?(:safe)).to eq(nil)

      session.update_formulas(b: '1')
      expect(session.update({})).to eq(a: 2, b: 1)
      expect(session.results).to eq(a: 2, b: 1, safe: 4)
      expect(session.error?).to eq(false)
    end

    it 'raises the original error in strict mode' do
      strict_session = calculator.session({ bad: '1 / 0' }, strict: true)
      expect { strict_session.update({}) }.to raise_error(Dentaku::ZeroDivisionError)
      expect(strict_session.error?(:bad)).to be_a(Dentaku::ZeroDivisionError)
    end

    it 'marks readers unbound when a formula is deleted' do
      session = calculator.session(base: '1 + 1', total: 'base + 1')
      expect(session.update({})).to eq(base: 2, total: 3)

      session.delete(:base)
      expect(session.update({})).to eq(total: :undefined)
      expect(session.error?(:total)).to be_a(Dentaku::UnboundVariableError)
    end

    it 'tracks cyclic dependencies through a dynamically selected branch' do
      session = calculator.session(a: 'IF(flag, b, 1)', b: 'a + 1')

      expect(session.update(flag: false)).to eq(a: 1, b: 2)
      expect(session.update(flag: true)).to eq(a: :undefined, b: :undefined)
      expect(session.dependencies(:a)).to eq(%w(flag b))
      expect(session.update(flag: false)).to eq(a: 1, b: 2)
      expect(session.dependencies(:a)).to eq(['flag'])
    end

    it 'matches permissive full evaluation across multiple rounds' do
      formulas = {
        a: 'x + y',
        b: 'IF(x > y, a, z)',
        c: 'a + b',
        bad: 'x / zero'
      }
      session = calculator.session(formulas)
      rounds = [
        [{ x: 2, y: 3, z: 10, zero: 0 }, {}],
        [{ x: 4, y: 1, z: 20, zero: 2 }, {}],
        [{ unused: 99, zero: 0 }, {}],
        [{}, { b: 'IF(x < 0, z, a)' }],
        [{ x: -1, z: 100 }, {}]
      ]
      current_formulas = formulas.dup

      rounds.each do |inputs, formula_changes|
        session.update_formulas(formula_changes) unless formula_changes.empty?
        current_formulas.merge!(formula_changes)
        session.update(inputs)
        expected = full_solve(calculator, current_formulas, session.inputs)
        expect(session.results.transform_keys(&:to_s)).to eq(expected)
      end
    end
  end
end
