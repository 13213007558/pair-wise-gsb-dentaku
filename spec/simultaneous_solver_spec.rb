require 'spec_helper'
require 'dentaku'

RSpec.describe 'simultaneous solving' do
  let(:calculator) { Dentaku::Calculator.new }

  describe 'Calculator#solve_simultaneous!' do
    it 'solves the two-variable affine quota example exactly' do
      calculator.store(base: 10, extra: 3)
      result = calculator.solve_simultaneous!(
        a: '0.2 * b + base',
        b: '0.5 * a + extra'
      )

      expect(result[:a]).to eq(Rational(106, 9))
      expect(result[:b]).to eq(Rational(80, 9))

      # substituting the solution back into the original formulas verifies
      expect(calculator.evaluate!('0.2 * b + base', result)).to be_within(1e-12).of(result[:a].to_f)
      expect(calculator.evaluate!('0.5 * a + extra', result)).to be_within(1e-12).of(result[:b].to_f)
    end

    it 'keeps terminating decimal solutions exact instead of binary floats' do
      result = calculator.solve_simultaneous!(a: 'b + 1', b: '2 * a - 4')
      expect(result[:a]).to eq(3)
      expect(result[:b]).to eq(2)
      expect(result[:a]).to be_a(Integer)

      decimal = calculator.solve_simultaneous!(a: 'b / 5', b: 'a + 4')
      expect(decimal[:a]).to eq(1)
      expect(decimal[:b]).to eq(BigDecimal('5'))
    end

    it 'solves several mutually dependent components together' do
      result = calculator.solve_simultaneous!(
        x: 'y + z',
        y: 'x - 4',
        z: '0.5 * x + 1'
      )

      expect(result).to eq(x: 6, y: 2, z: 4)
      result.each do |key, value|
        expect(calculator.evaluate!(key.to_s, result)).to eq(value)
      end
    end

    it 'solves multiple independent cycles in one call' do
      result = calculator.solve_simultaneous!(
        a: 'b + 1', b: '2 * a - 4',
        c: '2 * d', d: 'c - 3'
      )

      expect(result[:a]).to eq(3)
      expect(result[:b]).to eq(2)
      expect(result[:c]).to eq(6)
      expect(result[:d]).to eq(3)
    end

    it 'evaluates variables outside the ring with existing rules first' do
      calculator.store(base: 100)
      result = calculator.solve_simultaneous!(
        ring_a: 'ring_b + outside',
        ring_b: '2 * ring_a - outside - 210',
        outside: 'base * 2'
      )

      expect(result[:outside]).to eq(200)
      expect(result[:ring_a]).to eq(210)
      expect(result[:ring_b]).to eq(10)
    end

    it 'allows multiplication when the other side is independent of the ring' do
      result = calculator.solve_simultaneous!(a: '2 * b', b: 'a - 3')
      expect(result[:a]).to eq(6)
      expect(result[:b]).to eq(3)
    end

    it 'allows division only by a quantity independent of ring unknowns' do
      result = calculator.solve_simultaneous!(a: 'b / 2', b: 'a + 3')
      expect(result[:a]).to eq(3)
      expect(result[:b]).to eq(6)

      expect {
        calculator.solve_simultaneous!(a: '6 / b', b: 'a')
      }.to raise_error(Dentaku::NonLinearEquationError) { |error|
        expect(error.formula).to eq('a')
        expect(error.operator).to eq('/')
      }
    end

    it 'locates non-linear feedback at the responsible formula' do
      expect {
        calculator.solve_simultaneous!(
          a: 'b + 1',
          b: 'a * b',
          c: 'a + b'
        )
      }.to raise_error(Dentaku::NonLinearEquationError) { |error|
        expect(error.formula).to eq('b')
        expect(error.operator).to eq('*')
        expect(error.node).to be_a(Dentaku::AST::Multiplication)
      }
    end

    it 'rejects non-linear feedback through an exponent without iterating' do
      expect {
        calculator.solve_simultaneous!(a: 'a^2 - 2')
      }.to raise_error(Dentaku::NonLinearEquationError) { |error|
        expect(error.formula).to eq('a')
      }
    end

    it 'does not decide linearity from a single sample point' do
      # a * b happens to be constant for many scalar samples but is still a
      # bilinear dependency structurally; it must be rejected
      expect {
        calculator.solve_simultaneous!(a: 'b', b: 'a * b + 1')
      }.to raise_error(Dentaku::NonLinearEquationError)
    end

    it 'raises for contradictory equations and names the involved formulas' do
      expect {
        calculator.solve_simultaneous!(a: 'a + 1')
      }.to raise_error(Dentaku::InconsistentSystemError) { |error|
        expect(error.formulas).to eq(['a'])
      }

      expect {
        calculator.solve_simultaneous!(a: 'b', b: 'a + 2')
      }.to raise_error(Dentaku::InconsistentSystemError) { |error|
        expect(error.formulas).to contain_exactly('a', 'b')
      }
    end

    it 'returns a verified family of solutions for rank-deficient equations' do
      family = calculator.solve_simultaneous!(a: 'b', b: 'a')

      expect(family).to be_a(Dentaku::SimultaneousSolution)
      expect(family).to be_family
      expect(family).not_to be_unique
      expect(family.free_variables).to eq(['a'])
      expect(family).to be_verified

      expect(family.to_h).to eq('a' => 0, 'b' => 0)
      expect(family.to_h(a: 5)).to eq('a' => 5, 'b' => 5)
      expect(family.to_h(a: Rational(-3, 2))).to eq('a' => Rational(-3, 2), 'b' => Rational(-3, 2))
      expect(family.solution_for(:b, a: 9)).to eq(9)
    end

    it 'parameterises families with more than one free variable' do
      # one equation, three unknowns: two free parameters
      family = calculator.solve_simultaneous!(p: 'q + r', q: 'q', r: 'r')

      expect(family).to be_family
      expect(family.free_variables).to contain_exactly('q', 'r')
      expect(family.to_h(q: 2, r: 3)).to eq('p' => 5, 'q' => 2, 'r' => 3)
    end

    it 'includes equations that consume a solved ring in the same solution' do
      result = calculator.solve_simultaneous!(
        a: 'b + 1', b: '2 * a - 3', sum: 'a + b'
      )
      expect(result[:a]).to eq(2)
      expect(result[:b]).to eq(1)
      expect(result[:sum]).to eq(3)
    end

    it 'joins two free rings through an equation that depends on both' do
      family = calculator.solve_simultaneous!(
        a: 'b', b: 'a', c: 'd', d: 'c', total: 'a + c'
      )
      expect(family.free_variables).to contain_exactly('a', 'c')
      expect(family.to_h(a: 1, c: 2)).to eq(
        'a' => 1, 'b' => 1, 'c' => 2, 'd' => 2, 'total' => 3
      )
    end

    it 'leaves ordinary solve! rejecting cycles as before' do
      expect {
        calculator.solve!(health: 'happiness', happiness: 'health')
      }.to raise_error(TSort::Cyclic)
    end

    it 'rejects unbound external variables in a ring' do
      expect {
        calculator.solve_simultaneous!(a: 'b + unknown_thing', b: 'a')
      }.to raise_error(Dentaku::UnboundVariableError)
    end

    it 'detects a self-referential affine ring' do
      # a = 0.5*a + 3 is a self-loop with the unique solution a = 6
      result = calculator.solve_simultaneous!(a: '0.5 * a + 3')
      expect(result[:a]).to eq(6)
    end

    it 'can follow a ring that closes transitively through stored formulas' do
      calculator.store_formula('p', 'a * 2')
      result = calculator.solve_simultaneous!(a: 'p + 1')
      # a = 2a + 1 -> a = -1
      expect(result[:a]).to eq(-1)
    end

    it 'supports negation and parentheses inside ring formulas' do
      result = calculator.solve_simultaneous!(a: '-(b) + 4', b: '2 * (a - 1)')
      expect(result[:a]).to eq(2)
      expect(result[:b]).to eq(2)
    end

    it 'honors case sensitivity for ring unknowns and external constants' do
      sensitive = Dentaku::Calculator.new(case_sensitive: true)
      sensitive.store('Base' => 4)
      result = sensitive.solve_simultaneous!('A' => 'B + Base', 'B' => '2 * A - 6')
      expect(result['A']).to eq(2)
      expect(result['B']).to eq(-2)
    end

    it 'accepts a stored numeric string constant but rejects a non-numeric string' do
      calculator.store(k: '6')
      result = calculator.solve_simultaneous!(a: 'b + k', b: '2 * a - 18')
      expect(result[:a]).to eq(12)
      expect(result[:b]).to eq(6)

      calculator.store(j: '2 * 3')
      expect {
        calculator.solve_simultaneous!(a: 'b + j', b: 'a')
      }.to raise_error(Dentaku::NonLinearEquationError)
    end

    it 'returns exact Rational values for non-terminating decimal solutions' do
      result = calculator.solve_simultaneous!(x: '2 * y', y: 'x - 1/3')
      expect(result[:x]).to eq(Rational(2, 3))
      expect(result[:y]).to eq(Rational(1, 3))
    end
  end

  describe 'Calculator#solve_simultaneous' do
    it 'returns a SimultaneousSolution for a family without raising' do
      family = calculator.solve_simultaneous(a: 'b', b: 'a')
      expect(family).to be_a(Dentaku::SimultaneousSolution)
      expect(family).to be_family
      expect(family.to_h(a: 3)).to eq('a' => 3, 'b' => 3)
    end

    it 'returns a plain hash for a unique cycle' do
      result = calculator.solve_simultaneous(a: 'b / 2', b: 'a + 3')
      expect(result).to eq(a: 3, b: 6)
    end

    it 'returns :undefined for members of an inconsistent cycle with a handler' do
      result = calculator.solve_simultaneous(a: 'a + 1') { :undefined }
      expect(result).to eq(a: :undefined)
    end

    it 'returns :undefined for members of a non-linear cycle' do
      result = calculator.solve_simultaneous(a: 'a * a') { :undefined }
      expect(result).to eq(a: :undefined)
    end

    it 'still solves the remainder of the system when one cycle is unsolvable' do
      result = calculator.solve_simultaneous(
        bad: 'bad * bad',
        fine: '1 + 2'
      ) { :undefined }

      expect(result[:bad]).to eq(:undefined)
      expect(result[:fine]).to eq(3)
    end
  end
end
