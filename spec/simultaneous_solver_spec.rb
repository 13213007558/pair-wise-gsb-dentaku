require 'spec_helper'
require 'dentaku'

RSpec.describe 'simultaneous solving' do
  let(:calculator) { Dentaku::Calculator.new }

  def solve_simultaneous!(expressions)
    calculator.solve!(expressions, simultaneous: true)
  end

  it 'solves a two-variable numeric affine cycle after external values are known' do
    result = solve_simultaneous!(
      a: '0.2 * b + base',
      b: '0.5 * a + extra',
      base: 1,
      extra: 1
    )

    expect(result.status).to eq(:unique)
    expect(result.solution).to eq(a: Rational(4, 3), b: Rational(5, 3), base: 1, extra: 1)
    expect(result.verified?).to be(true)
  end

  it 'solves several mutually dependent components in one cycle' do
    result = solve_simultaneous!(
      a: 'b + c + 1',
      b: '2 * c',
      c: 'a - 7'
    )

    expect(result.status).to eq(:unique)
    expect(result.solution).to eq(a: 10, b: 6, c: 3)
    expect(result.verified?).to be(true)
  end

  it 'preserves exact decimal constants in the returned solution' do
    result = solve_simultaneous!(
      a: '0.5 * b',
      b: 'a + 0.25'
    )

    expect(result.solution[:a]).to eq(BigDecimal('0.25'))
    expect(result.solution[:b]).to eq(BigDecimal('0.5'))
  end

  it 'evaluates variables outside a cycle before solving the cycle' do
    calculator.store(external: 3)
    result = solve_simultaneous!(
      a: '0.5 * b + offset',
      b: 'a + 1',
      offset: 'external * 2',
      downstream: 'a + 1'
    )

    expect(result.status).to eq(:unique)
    expect(result.solution).to eq(a: 13, b: 14, offset: 6, downstream: 14)
  end

  it 'solves cycles formed indirectly through stored formulas' do
    calculator.store_formula(:helper, 'a + 1')

    result = solve_simultaneous!(
      a: 'helper',
      b: 'a'
    )

    expect(result.status).to eq(:no_solution)
  end

  it 'keeps independent cycles separately solvable' do
    result = solve_simultaneous!(
      a: 'b',
      b: 'a',
      c: 'd + 1',
      d: 'c - 1'
    )

    expect(result.status).to eq(:free_parameter_solution)
    expect(result.free_variables).to contain_exactly(:b, :d)
  end

  it 'tolerates redundant affine identities in a solvable cycle' do
    result = solve_simultaneous!(
      a: 'b + 1',
      b: 'a - 1',
      c: 'a - b'
    )

    expect(result.status).to eq(:free_parameter_solution)
    expect(result.solution[:c]).to eq(1)
  end

  it 'returns a free-parameter solution family for a rank-deficient system' do
    result = solve_simultaneous!(
      a: 'b + 1',
      b: 'a - 1',
      d: '2 * a'
    )

    expect(result.status).to eq(:free_parameter_solution)
    expect(result.free_variables).to eq([:b])
    expect(result.solution[:b]).to eq(Dentaku::AffineExpression.new({ 'b' => 1 }))
    expect(result.solution[:a]).to eq(Dentaku::AffineExpression.new({ 'b' => 1 }, 1))
    expect(result.solution[:d]).to eq(Dentaku::AffineExpression.new({ 'b' => 2 }, 2))
    expect(result.verified?).to be(true)
    expect(result.values(b: 2)).to eq(a: 3, b: 2, d: 6)
  end

  it 'reports contradictory equations as having no solution' do
    result = calculator.solve(
      { a: 'b + 1', b: 'a' },
      { simultaneous: true }
    )

    expect(result.status).to eq(:no_solution)
    expect(result.solution).to eq({})
    expect(result.verified?).to be(false)
  end

  it 'allows division only by a side independent of the cycle' do
    result = solve_simultaneous!(
      a: 'b / 2 + 1',
      b: 'a + 1'
    )

    expect(result.status).to eq(:unique)
    expect(result.solution).to eq(a: 3, b: 4)
  end

  it 'does not treat division by an unknown as affine' do
    expect {
      solve_simultaneous!(a: '1 / b', b: 'a')
    }.to raise_error(Dentaku::NonlinearEquationError) do |error|
      expect(error.assigned_to).to eq(:a)
      expect(error.formula).to eq('1 / b')
    end
  end

  it 'does not treat a constant divided by an unknown as affine' do
    expect {
      solve_simultaneous!(a: '2 / b', b: 'a')
    }.to raise_error(Dentaku::NonlinearEquationError)
  end

  it 'does not treat feedback from multiplying two unknown sides as affine' do
    expect {
      solve_simultaneous!(a: 'b * c', b: 'a', c: 'b')
    }.to raise_error(Dentaku::NonlinearEquationError)
  end

  it 'does not treat an unknown exponent as affine' do
    expect {
      solve_simultaneous!(a: '2 ^ b', b: 'a')
    }.to raise_error(Dentaku::NonlinearEquationError)
  end

  it 'does not infer linearity from one conditional branch' do
    expect {
      solve_simultaneous!(
        a: 'IF(b > 0, b, 2 * b)',
        b: 'a'
      )
    }.to raise_error(Dentaku::NonlinearEquationError) do |error|
      expect(error.assigned_to).to eq(:a)
    end
  end

  it 'locates nonlinear feedback in the formula that contains it' do
    expect {
      solve_simultaneous!(
        a: 'b + 1',
        b: 'a * a',
        c: 'a + b'
      )
    }.to raise_error(Dentaku::NonlinearEquationError) do |error|
      expect(error.assigned_to).to eq(:b)
    end
  end

  it 'keeps ordinary solve cycles unchanged when simultaneous mode is not enabled' do
    expect {
      calculator.solve!(a: 'b', b: 'a')
    }.to raise_error(TSort::Cyclic)
  end
end
